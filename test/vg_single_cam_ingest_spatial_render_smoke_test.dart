// vg_single_cam_ingest_spatial_render_smoke_test.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-SINGLE-CAM-INGEST-DESCRIPTOR-
// SPATIAL-RENDER: Android True-DAG Phase 3 single-camera ingest + dynamic-
// descriptor spatial render smoke Dart model & MethodChannel tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const _kCanonicalProofBoundary =
    'single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_gles_oes_render_readback_only_no_concurrent_camera_no_vulkan_no_recording_no_export_no_product';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'success': true,
  'started': true,
  'textureId': 42,
  'apiLevel': 33,
  'hasCameraPermission': true,
  'attemptedOpen': true,
  'opened': true,
  'sessionConfigured': true,
  'repeatingStarted': true,
  'frameReceived': true,
  'cameraId': '0',
  'selectedLensFacing': 'back',
  'selectedWidth': 640,
  'selectedHeight': 480,
  'imageFormatName': 'YUV_420_888',
  'hardwareBufferAvailable': true,
  'hardwareBufferClosed': true,
  'imageClosed': true,
  'syncFenceAwaited': true,
  'syncFenceClosed': true,
  'syntheticBufferAllocated': true,
  'syntheticBufferClosed': true,
  'nativeInvoked': true,
  'sessionClosed': true,
  'deviceClosed': true,
  'imageReaderClosed': true,
  'surfaceProducerReleased': false,
  'decision': 'singleCamIngestSpatialRenderPassed',
  'reasons': const <String>[],
  'events': const <String>['onOpened', 'onConfigured', 'onImageAvailable'],
  'diagnostics': const <String, Object?>{},
  'durationMs': 120,
  'proofBoundary': _kCanonicalProofBoundary,
  'raw':
      'status=PASS;'
      'width=640;'
      'height=480;'
      'clientVersion=3;'
      'vendor=ARM;'
      'renderer=Mali-G78;'
      'version=OpenGL ES 3.2;'
      'cameraDescribe=success;'
      'cameraFormatIsYcbcr420=true;'
      'rgbaDescribe=success;'
      'rgbaFill=success;'
      'initialize=success;'
      'attach=success;'
      'importCamera=success;'
      'handleCamera=1001;'
      'targetCamera=36197;'
      'importRgba=success;'
      'handleRgba=1002;'
      'targetRgba=3553;'
      'descriptorParse=success;'
      'descriptorParseLastError=;'
      'layoutModeResolved=pip;'
      'anchorResolved=freeFloating;'
      'directionResolved=topBottom;'
      'layoutConvert=success;'
      'layoutConvertLastError=none;'
      'primaryRectX=0;'
      'primaryRectY=0;'
      'primaryRectW=640;'
      'primaryRectH=480;'
      'secondaryRectX=320;'
      'secondaryRectY=80;'
      'secondaryRectW=192;'
      'secondaryRectH=108;'
      'renderDraw=success;'
      'renderDrawLastError=none;'
      'primaryTargetOk=true;'
      'secondaryTargetOk=true;'
      'primarySampleReadOk=true;'
      'secondarySampleReadOk=true;'
      'secondaryColorOk=true;'
      'presentLane=success;'
      'presentLaneLastError=none;'
      'releaseCamera=success;'
      'releaseCameraFence=-1;'
      'hasCameraAfterRelease=false;'
      'releaseRgba=success;'
      'releaseRgbaFence=-1;'
      'hasRgbaAfterRelease=false;'
      'postReleaseLane=rejected_as_expected;'
      'postReleaseLastError=invalid_buffer_handle;'
      'detach=success;'
      'shutdown=success;'
      'idempotentShutdown=success;'
      'proofBoundary=$_kCanonicalProofBoundary;'
      'lastError=none',
  'metrics': const <String, Object?>{
    'clientVersion': 3,
    'vendor': 'ARM',
    'renderer': 'Mali-G78',
    'version': 'OpenGL ES 3.2',
    'cameraDescribe': 'success',
    'cameraFormatIsYcbcr420': true,
    'rgbaDescribe': 'success',
    'rgbaFill': 'success',
    'initialize': 'success',
    'attach': 'success',
    'importCamera': 'success',
    'handleCamera': 1001,
    'targetCamera': 36197,
    'importRgba': 'success',
    'handleRgba': 1002,
    'targetRgba': 3553,
    'descriptorParse': 'success',
    'descriptorParseLastError': '',
    'layoutModeResolved': 'pip',
    'anchorResolved': 'freeFloating',
    'directionResolved': 'topBottom',
    'layoutConvert': 'success',
    'layoutConvertLastError': 'none',
    'primaryRectX': 0,
    'primaryRectY': 0,
    'primaryRectW': 640,
    'primaryRectH': 480,
    'secondaryRectX': 320,
    'secondaryRectY': 80,
    'secondaryRectW': 192,
    'secondaryRectH': 108,
    'renderDraw': 'success',
    'renderDrawLastError': 'none',
    'primaryTargetOk': true,
    'secondaryTargetOk': true,
    'primarySampleReadOk': true,
    'secondarySampleReadOk': true,
    'secondaryColorOk': true,
    'presentLane': 'success',
    'presentLaneLastError': 'none',
    'releaseCamera': 'success',
    'releaseCameraFence': -1,
    'hasCameraAfterRelease': false,
    'releaseRgba': 'success',
    'releaseRgbaFence': -1,
    'hasRgbaAfterRelease': false,
    'postReleaseLane': 'rejected_as_expected',
    'postReleaseLastError': 'invalid_buffer_handle',
    'detach': 'success',
    'shutdown': 'success',
    'idempotentShutdown': 'success',
  },
  'lastError': 'none',
  if (overrides != null) ...overrides,
};

VGSingleCamIngestSpatialRenderSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGSingleCamIngestSpatialRenderSmokeReport.fromMap(
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

  group('VGSingleCamIngestSpatialRenderSmokeDecision fromRaw', () {
    test('maps every camelCase decision name via value.name', () {
      for (final value in VGSingleCamIngestSpatialRenderSmokeDecision.values) {
        if (value ==
                VGSingleCamIngestSpatialRenderSmokeDecision
                    .noSupportedYuvSize ||
            value ==
                VGSingleCamIngestSpatialRenderSmokeDecision.cameraOpenTimeout ||
            value ==
                VGSingleCamIngestSpatialRenderSmokeDecision
                    .noFrameWithinTimeout) {
          continue;
        }
        expect(
          VGSingleCamIngestSpatialRenderSmokeDecision.fromRaw(value.name),
          equals(value),
        );
      }
    });

    test('maps the 3 explicit snake_case native decision strings', () {
      expect(
        VGSingleCamIngestSpatialRenderSmokeDecision.fromRaw(
          'no_supported_yuv_size',
        ),
        equals(VGSingleCamIngestSpatialRenderSmokeDecision.noSupportedYuvSize),
      );
      expect(
        VGSingleCamIngestSpatialRenderSmokeDecision.fromRaw(
          'camera_open_timeout',
        ),
        equals(VGSingleCamIngestSpatialRenderSmokeDecision.cameraOpenTimeout),
      );
      expect(
        VGSingleCamIngestSpatialRenderSmokeDecision.fromRaw(
          'no_frame_within_timeout',
        ),
        equals(
          VGSingleCamIngestSpatialRenderSmokeDecision.noFrameWithinTimeout,
        ),
      );
    });

    test(
      'falls back to nativeRenderFailed for unknown, non-string, or null values',
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
            VGSingleCamIngestSpatialRenderSmokeDecision.fromRaw(invalid),
            equals(
              VGSingleCamIngestSpatialRenderSmokeDecision.nativeRenderFailed,
            ),
          );
        }
      },
    );
  });

  group('VGSingleCamIngestSpatialRenderSmokeReport fromMap and toMap', () {
    test(
      'pass report (freeFloating PiP lane) parses and round-trips all fields cleanly',
      () {
        final report = VGSingleCamIngestSpatialRenderSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.success, isTrue);
        expect(
          report.decision,
          equals(
            VGSingleCamIngestSpatialRenderSmokeDecision
                .singleCamIngestSpatialRenderPassed,
          ),
        );
        expect(report.isPass, isTrue);
        expect(report.isPermissionDenied, isFalse);
        expect(report.isDescriptorRejected, isFalse);
        expect(report.isCameraIngestUnsupported, isFalse);
        expect(report.isDisposed, isFalse);

        expect(report.hasCanonicalProofBoundary, isTrue);
        expect(report.proofBoundary, equals(_kCanonicalProofBoundary));
        expect(report.textureId, equals(42));
        expect(report.surfaceProducerReleased, isFalse);
        expect(report.selectedWidth, equals(640));
        expect(report.selectedHeight, equals(480));
        expect(report.imageFormatName, equals('YUV_420_888'));
        expect(report.lastError, equals('none'));

        // Camera lifecycle
        expect(report.attemptedOpen, isTrue);
        expect(report.opened, isTrue);
        expect(report.sessionConfigured, isTrue);
        expect(report.repeatingStarted, isTrue);
        expect(report.frameReceived, isTrue);
        expect(report.hardwareBufferAvailable, isTrue);
        expect(report.hardwareBufferClosed, isTrue);
        expect(report.imageClosed, isTrue);
        expect(report.syncFenceAwaited, isTrue);
        expect(report.syncFenceClosed, isTrue);
        expect(report.syntheticBufferAllocated, isTrue);
        expect(report.syntheticBufferClosed, isTrue);
        expect(report.nativeInvoked, isTrue);
        expect(report.isCleanedUp, isTrue);

        // Native import lanes
        expect(report.cameraDescribePass, isTrue);
        expect(report.cameraFormatIsYcbcr420, isTrue);
        expect(report.importCameraPass, isTrue);
        expect(report.rgbaDescribePass, isTrue);
        expect(report.rgbaFillPass, isTrue);
        expect(report.importRgbaPass, isTrue);
        expect(report.initializePass, isTrue);
        expect(report.attachPass, isTrue);

        // Descriptor parse / layout conversion lanes
        expect(report.descriptorParsePass, isTrue);
        expect(report.layoutModeResolved, equals('pip'));
        expect(report.anchorResolved, equals('freeFloating'));
        expect(report.directionResolved, equals('topBottom'));
        expect(report.layoutConvertPass, isTrue);
        expect(report.primaryRectX, equals(0));
        expect(report.primaryRectY, equals(0));
        expect(report.primaryRectWidth, equals(640));
        expect(report.primaryRectHeight, equals(480));
        expect(report.secondaryRectX, equals(320));
        expect(report.secondaryRectY, equals(80));
        expect(report.secondaryRectWidth, equals(192));
        expect(report.secondaryRectHeight, equals(108));

        // Render / readback lanes
        expect(report.renderDrawPass, isTrue);
        expect(report.primaryTargetOkPass, isTrue);
        expect(report.secondaryTargetOkPass, isTrue);
        expect(report.primarySampleReadOkPass, isTrue);
        expect(report.secondarySampleReadOkPass, isTrue);
        expect(report.secondaryColorOkPass, isTrue);
        expect(report.presentLanePass, isTrue);

        // Release / teardown lanes
        expect(report.releaseCameraPass, isTrue);
        expect(report.releaseRgbaPass, isTrue);
        expect(report.hasCameraAfterReleasePass, isTrue);
        expect(report.hasRgbaAfterReleasePass, isTrue);
        expect(report.postReleaseLanePass, isTrue);
        expect(report.detachPass, isTrue);
        expect(report.shutdownPass, isTrue);
        expect(report.idempotentShutdownPass, isTrue);

        // Aggregate
        expect(report.allNativeLanesPass, isTrue);

        final serialized = report.toMap();
        expect(serialized['success'], isTrue);
        expect(
          serialized['decision'],
          equals('singleCamIngestSpatialRenderPassed'),
        );
        expect(serialized['raw'], equals(report.raw));
        expect(serialized['proofBoundary'], equals(report.proofBoundary));
        expect(serialized['textureId'], equals(42));
        expect(serialized['lastError'], equals('none'));

        final roundTrip = VGSingleCamIngestSpatialRenderSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test(
      'malformed descriptor lane report reflects native descriptor rejection after a full camera capture',
      () {
        final report = VGSingleCamIngestSpatialRenderSmokeReport.fromMap(
          _createSampleRawMap({
            'success': false,
            'decision': 'descriptorRejected',
            'reasons': const <String>[
              'descriptor_rejected:unknown_layout_mode',
            ],
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

        expect(report.success, isFalse);
        expect(
          report.decision,
          equals(
            VGSingleCamIngestSpatialRenderSmokeDecision.descriptorRejected,
          ),
        );
        expect(report.isDescriptorRejected, isTrue);
        // The camera lifecycle still completed fully before native rejected
        // the descriptor.
        expect(report.attemptedOpen, isTrue);
        expect(report.frameReceived, isTrue);
        expect(report.descriptorParsePass, isFalse);
        expect(report.layoutConvertPass, isFalse);
        expect(report.renderDrawPass, isFalse);
        expect(report.lastError, equals('unknown_layout_mode'));
        expect(report.allNativeLanesPass, isFalse);
      },
    );

    test(
      'cameraIngestUnsupported lane report reflects a null/unimportable camera buffer',
      () {
        final report = VGSingleCamIngestSpatialRenderSmokeReport.fromMap(
          _createSampleRawMap({
            'success': false,
            'decision': 'cameraIngestUnsupported',
            'reasons': const <String>['yuv_ahb_import_unsupported_format'],
            'hardwareBufferAvailable': false,
            'raw': 'status=FAIL;lastError=yuv_ahb_import_unsupported_format',
            'metrics': const <String, Object?>{},
            'lastError': 'yuv_ahb_import_unsupported_format',
          }),
        );

        expect(report.success, isFalse);
        expect(
          report.decision,
          equals(
            VGSingleCamIngestSpatialRenderSmokeDecision.cameraIngestUnsupported,
          ),
        );
        expect(report.isCameraIngestUnsupported, isTrue);
        expect(report.reasons, contains('yuv_ahb_import_unsupported_format'));
      },
    );

    test('defensive fromMap handles non-map input', () {
      final report = VGSingleCamIngestSpatialRenderSmokeReport.fromMap(
        'not_a_map',
      );
      expect(report.success, isFalse);
      expect(
        report.decision,
        equals(VGSingleCamIngestSpatialRenderSmokeDecision.nativeRenderFailed),
      );
      expect(report.lastError, equals('native_result_not_a_map'));
      expect(report.textureId, equals(-1));
    });
  });

  group('VGSingleCamIngestSpatialRenderSmokeReport value semantics', () {
    test('equal reports compare equal and share hashCode', () {
      final a = _createSampleReport();
      final b = _createSampleReport();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing fields produce unequal reports', () {
      final base = _createSampleReport();
      final diffs = <Map<String, Object?>>[
        {'success': false, 'decision': 'nativeRenderFailed'},
        {'textureId': 99},
        {'surfaceProducerReleased': true},
        {'selectedWidth': 1280},
        {'selectedHeight': 720},
        {'lastError': 'something_else'},
        {'proofBoundary': 'different_boundary'},
      ];
      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('start & dispose MethodChannel wrappers', () {
    test(
      'start invokes with descriptor map and default maxWidth/maxHeight/timeout',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_single_cam_ingest_spatial_smoke_channel',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return <String, Object?>{'started': true, 'textureId': 77};
        });

        final descriptor =
            VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip()
                .toMap();
        final startResult =
            await VGSingleCamIngestSpatialRenderSmokeReport.startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
              descriptor: descriptor,
              channel: channel,
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke'),
        );
        expect(
          capturedCall!.arguments,
          equals({
            'descriptor': descriptor,
            'maxWidth': 640,
            'maxHeight': 480,
            'timeoutMs': 10000,
          }),
        );
        expect(startResult.textureId, equals(77));
        expect(startResult.maxWidth, equals(640));
        expect(startResult.maxHeight, equals(480));
      },
    );

    test(
      'start invokes with custom maxWidth/maxHeight/timeout and uses default channel',
      () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return <String, Object?>{'started': true, 'textureId': 88};
        });

        final descriptor =
            VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit()
                .toMap();
        final startResult =
            await VGSingleCamIngestSpatialRenderSmokeReport.startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
              descriptor: descriptor,
              maxWidth: 1280,
              maxHeight: 720,
              timeout: const Duration(seconds: 5),
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.arguments,
          equals({
            'descriptor': descriptor,
            'maxWidth': 1280,
            'maxHeight': 720,
            'timeoutMs': 5000,
          }),
        );
        expect(startResult.textureId, equals(88));
        expect(startResult.maxWidth, equals(1280));
        expect(startResult.maxHeight, equals(720));
      },
    );

    test(
      'start allows a deliberately malformed/unknown descriptor map through the wrapper',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_single_cam_ingest_spatial_smoke_malformed',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return <String, Object?>{'started': true, 'textureId': 5};
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

        await VGSingleCamIngestSpatialRenderSmokeReport.startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
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
        'test_single_cam_ingest_spatial_smoke_non_map',
      );
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return 'unexpected_non_map';
      });

      final startResult =
          await VGSingleCamIngestSpatialRenderSmokeReport.startAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip()
                    .toMap(),
            channel: channel,
          );

      expect(startResult.textureId, equals(-1));
      expect(startResult.maxWidth, equals(640));
      expect(startResult.maxHeight, equals(480));
    });

    test('dispose invokes with textureId and returns release status', () async {
      MethodCall? capturedCall;
      const channel = MethodChannel(
        'test_single_cam_ingest_spatial_smoke_dispose',
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
          await VGSingleCamIngestSpatialRenderSmokeReport.disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
            textureId: 77,
            channel: channel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke'),
      );
      expect(capturedCall!.arguments, equals({'textureId': 77}));
      expect(released, isTrue);
    });

    test('dispose handles defensive non-map response', () async {
      const channel = MethodChannel(
        'test_single_cam_ingest_spatial_smoke_dispose_non_map',
      );
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        return null;
      });

      final released =
          await VGSingleCamIngestSpatialRenderSmokeReport.disposeAndroidDagPhase3SingleCamIngestSpatialRenderSmoke(
            textureId: 77,
            channel: channel,
          );

      expect(released, isFalse);
    });
  });
}
