// vg_single_cam_ingest_vulkan_spatial_render_smoke_test.dart
// vanguard_media_engine -- P3-MULTICAM-NODE-SINGLE-CAM-INGEST-VULKAN-SPATIAL-RENDER:
// Android True-DAG Phase 3 single-camera ingest + Vulkan spatial render smoke
// Dart model & MethodChannel tests.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const String _proofBoundary =
    'single_camera_ingest_buffer_queue_dynamic_descriptor_spatial_vulkan_render_readback_only_no_concurrent_camera_no_gles_no_recording_no_export_no_product';
const String _passMarker =
    'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_PASS';
const String _failMarker =
    'ANDROID_DAG_PHASE3_SINGLE_CAM_INGEST_VULKAN_SPATIAL_RENDER_FAIL';
const String _startMethod =
    'startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke';
const String _disposeMethod =
    'disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke';
const String _callbackMethod =
    'onAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmokeComplete';

const List<String> _gateKeys = <String>[
  'descriptorParseOk',
  'descriptorRejectedBeforeVulkanOk',
  'vulkanSetupOk',
  'cameraImportOk',
  'syntheticImportOk',
  'layoutConvertOk',
  'renderReadbackOk',
  'helperResourcesReleasedOk',
  'diagnosticTeardownOk',
];

Map<String, Object?> _createSamplePassRawMap([
  Map<String, Object?>? overrides,
]) => {
  'success': true,
  'started': true,
  'runId': 42,
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
  'nativeInvoked': true,
  'sessionClosed': true,
  'deviceClosed': true,
  'imageReaderClosed': true,
  'pass': true,
  'decision': 'singleCamIngestVulkanSpatialRenderPassed',
  'status': 'PASS',
  'marker': _passMarker,
  'proofBoundary': _proofBoundary,
  'failureReason': '',
  'lastError': '',
  'reasons': const <String>[],
  'events': const <String>[
    'onOpened',
    'onConfigured',
    'onImageAvailable',
    'nativeRenderAttempted',
  ],
  'diagnostics': const <String, Object?>{},
  'durationMs': 120,
  'raw': '{"pass":true,"status":"PASS"}',
  'descriptorParseOk': true,
  'descriptorRejectedBeforeVulkanOk': false,
  'vulkanSetupOk': true,
  'cameraImportOk': true,
  'syntheticImportOk': true,
  'layoutConvertOk': true,
  'renderReadbackOk': true,
  'helperResourcesReleasedOk': true,
  'diagnosticTeardownOk': true,
  'details': const <String, Object?>{
    'layoutModeResolved': 'pip',
    'pipAnchorResolved': 'freeFloating',
    'splitDirectionResolved': 'topBottom',
    'rejectionReason': '',
    'cameraReleaseOk': true,
    'teardownWaitIdleOk': true,
    'teardownHandlesNull': true,
    'vulkanUnsupported': false,
    'cameraIngestUnsupported': false,
  },
  if (overrides != null) ...overrides,
};

Map<String, Object?> _createSampleRejectionRawMap([
  Map<String, Object?>? overrides,
]) => {
  'success': false,
  'started': true,
  'runId': 43,
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
  'nativeInvoked': true,
  'sessionClosed': true,
  'deviceClosed': true,
  'imageReaderClosed': true,
  'pass': false,
  'decision': 'descriptorRejected',
  'status': 'FAIL',
  'marker': _failMarker,
  'proofBoundary': _proofBoundary,
  'failureReason': 'descriptor_rejected:unknown_layout_mode',
  'lastError': 'descriptor_rejected:unknown_layout_mode',
  'reasons': const <String>['descriptor_rejected:unknown_layout_mode'],
  'events': const <String>[
    'onOpened',
    'onConfigured',
    'onImageAvailable',
    'nativeRenderAttempted',
  ],
  'diagnostics': const <String, Object?>{},
  'durationMs': 100,
  'raw': '{"pass":false,"status":"FAIL"}',
  'descriptorParseOk': false,
  'descriptorRejectedBeforeVulkanOk': true,
  'vulkanSetupOk': false,
  'cameraImportOk': false,
  'syntheticImportOk': false,
  'layoutConvertOk': false,
  'renderReadbackOk': false,
  'helperResourcesReleasedOk': false,
  'diagnosticTeardownOk': false,
  'details': const <String, Object?>{
    'layoutModeResolved': '',
    'pipAnchorResolved': '',
    'splitDirectionResolved': '',
    'rejectionReason': 'unknown_layout_mode',
    'vulkanUnsupported': false,
    'cameraIngestUnsupported': false,
  },
  if (overrides != null) ...overrides,
};

VGSingleCamIngestVulkanSpatialRenderSmokeReport _createSamplePassReport([
  Map<String, Object?>? overrides,
]) => VGSingleCamIngestVulkanSpatialRenderSmokeReport.fromMap(
  _createSamplePassRawMap(overrides),
);

VGSingleCamIngestVulkanSpatialRenderSmokeReport _createSampleRejectionReport([
  Map<String, Object?>? overrides,
]) => VGSingleCamIngestVulkanSpatialRenderSmokeReport.fromMap(
  _createSampleRejectionRawMap(overrides),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('contract constants', () {
    test('canonical strings match the required frozen contract', () {
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeReport.proofBoundaryConstant,
        equals(_proofBoundary),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeReport.passMarker,
        equals(_passMarker),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeReport.failMarker,
        equals(_failMarker),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeReport.startMethodName,
        equals(_startMethod),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeReport.disposeMethodName,
        equals(_disposeMethod),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeReport.callbackMethodName,
        equals(_callbackMethod),
      );
    });

    test(
      'gate keys match specification and validPassGateKeys excludes rejection gate',
      () {
        expect(
          VGSingleCamIngestVulkanSpatialRenderSmokeReport.allGateKeys,
          orderedEquals(_gateKeys),
        );
        expect(
          VGSingleCamIngestVulkanSpatialRenderSmokeReport.validPassGateKeys,
          orderedEquals(const <String>[
            'descriptorParseOk',
            'vulkanSetupOk',
            'cameraImportOk',
            'syntheticImportOk',
            'layoutConvertOk',
            'renderReadbackOk',
            'helperResourcesReleasedOk',
            'diagnosticTeardownOk',
          ]),
        );
        expect(
          VGSingleCamIngestVulkanSpatialRenderSmokeReport.validPassGateKeys,
          isNot(contains('descriptorRejectedBeforeVulkanOk')),
        );
        expect(
          VGSingleCamIngestVulkanSpatialRenderSmokeReport
              .descriptorRejectionGateKeys,
          orderedEquals(const <String>['descriptorRejectedBeforeVulkanOk']),
        );
      },
    );
  });

  group('VGSingleCamIngestVulkanSpatialRenderSmokeDecision fromRaw', () {
    test('maps every decision enum value via value.name', () {
      for (final value
          in VGSingleCamIngestVulkanSpatialRenderSmokeDecision.values) {
        expect(
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw(value.name),
          equals(value),
        );
      }
    });

    test('maps explicit snake_case native decision strings', () {
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw(
          'no_supported_yuv_size',
        ),
        equals(
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision.noSupportedYuvSize,
        ),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw(
          'camera_open_timeout',
        ),
        equals(
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision.cameraOpenTimeout,
        ),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw(
          'no_frame_within_timeout',
        ),
        equals(
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision
              .noFrameWithinTimeout,
        ),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw(
          'malformed_descriptor_shape',
        ),
        equals(
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision
              .malformedDescriptorShape,
        ),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw(
          'camera_permission_denied',
        ),
        equals(
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision
              .cameraPermissionDenied,
        ),
      );
    });

    test('maps pass/fail/unsupported aliases', () {
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw('pass'),
        equals(
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision
              .singleCamIngestVulkanSpatialRenderPassed,
        ),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw('FAIL'),
        equals(
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision.nativeRenderFailed,
        ),
      );
      expect(
        VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw(
          'UNSUPPORTED',
        ),
        equals(
          VGSingleCamIngestVulkanSpatialRenderSmokeDecision.nativeUnsupported,
        ),
      );
    });

    test('falls back safely for null, empty, or non-string inputs', () {
      const invalidValues = <Object?>[null, '', 123, 4.5, true, <String>[]];
      for (final invalid in invalidValues) {
        final result =
            VGSingleCamIngestVulkanSpatialRenderSmokeDecision.fromRaw(invalid);
        expect(
          result ==
                  VGSingleCamIngestVulkanSpatialRenderSmokeDecision
                      .harnessException ||
              result ==
                  VGSingleCamIngestVulkanSpatialRenderSmokeDecision
                      .nativeRenderFailed,
          isTrue,
        );
      }
    });
  });

  group('VGSingleCamIngestVulkanSpatialRenderSmokeReport fromMap / toMap', () {
    test('pass report parses all fields, camera lifecycle, and gates', () {
      final report = _createSamplePassReport();

      expect(report.success, isTrue);
      expect(report.started, isTrue);
      expect(report.runId, equals(42));
      expect(report.apiLevel, equals(33));
      expect(report.hasCameraPermission, isTrue);
      expect(report.attemptedOpen, isTrue);
      expect(report.opened, isTrue);
      expect(report.sessionConfigured, isTrue);
      expect(report.repeatingStarted, isTrue);
      expect(report.frameReceived, isTrue);
      expect(report.cameraId, equals('0'));
      expect(report.selectedLensFacing, equals('back'));
      expect(report.selectedWidth, equals(640));
      expect(report.selectedHeight, equals(480));
      expect(report.imageFormatName, equals('YUV_420_888'));
      expect(report.hardwareBufferAvailable, isTrue);
      expect(report.hardwareBufferClosed, isTrue);
      expect(report.imageClosed, isTrue);
      expect(report.syncFenceAwaited, isTrue);
      expect(report.syncFenceClosed, isTrue);
      expect(report.nativeInvoked, isTrue);
      expect(report.sessionClosed, isTrue);
      expect(report.deviceClosed, isTrue);
      expect(report.imageReaderClosed, isTrue);
      expect(report.isCleanedUp, isTrue);

      expect(report.pass, isTrue);
      expect(report.isPass, isTrue);
      expect(report.isFail, isFalse);
      expect(report.isUnsupported, isFalse);
      expect(report.isCameraIngestUnsupported, isFalse);
      expect(report.isDescriptorRejected, isFalse);
      expect(report.isDisposed, isFalse);
      expect(report.status, equals('PASS'));
      expect(report.marker, equals(_passMarker));
      expect(report.hasPassMarker, isTrue);
      expect(report.hasFailMarker, isFalse);
      expect(report.hasCanonicalProofBoundary, isTrue);
      expect(report.failureReason, isEmpty);

      // Gates
      expect(report.descriptorParseOk, isTrue);
      expect(report.descriptorRejectedBeforeVulkanOk, isFalse);
      expect(report.vulkanSetupOk, isTrue);
      expect(report.cameraImportOk, isTrue);
      expect(report.syntheticImportOk, isTrue);
      expect(report.layoutConvertOk, isTrue);
      expect(report.renderReadbackOk, isTrue);
      expect(report.helperResourcesReleasedOk, isTrue);
      expect(report.diagnosticTeardownOk, isTrue);

      expect(report.setupPass, isTrue);
      expect(report.renderPass, isTrue);
      expect(report.resourceLifecyclePass, isTrue);
      expect(report.allNativeLanesPass, isTrue);
      expect(report.isValidPass, isTrue);
      expect(report.isVerifiedPass, isTrue);
      expect(report.isVerifiedDescriptorRejection, isFalse);

      // Details
      expect(report.layoutModeResolved, equals('pip'));
      expect(report.pipAnchorResolved, equals('freeFloating'));
      expect(report.splitDirectionResolved, equals('topBottom'));
      expect(report.rejectionReason, isEmpty);

      // Round trip
      final map = report.toMap();
      expect(map['success'], isTrue);
      expect(map['runId'], equals(42));
      expect(
        map['decision'],
        equals('singleCamIngestVulkanSpatialRenderPassed'),
      );
      expect(map['proofBoundary'], equals(_proofBoundary));
      expect(map['marker'], equals(_passMarker));

      final roundTrip = VGSingleCamIngestVulkanSpatialRenderSmokeReport.fromMap(
        map,
      );
      expect(roundTrip, equals(report));
      expect(roundTrip.hashCode, equals(report.hashCode));
    });

    test(
      'descriptor rejection report reflects native rejection after full camera capture',
      () {
        final report = _createSampleRejectionReport();

        expect(report.success, isFalse);
        expect(report.pass, isFalse);
        expect(report.isDescriptorRejected, isTrue);
        expect(report.isPass, isFalse);
        expect(report.attemptedOpen, isTrue);
        expect(report.frameReceived, isTrue);
        expect(report.hasFailMarker, isTrue);
        expect(report.hasPassMarker, isFalse);
        expect(report.hasCanonicalProofBoundary, isTrue);

        expect(report.descriptorParseOk, isFalse);
        expect(report.descriptorRejectedBeforeVulkanOk, isTrue);
        expect(report.vulkanSetupOk, isFalse);
        expect(report.cameraImportOk, isFalse);
        expect(report.syntheticImportOk, isFalse);
        expect(report.layoutConvertOk, isFalse);
        expect(report.renderReadbackOk, isFalse);

        expect(report.rejectionReason, equals('unknown_layout_mode'));
        expect(report.isVerifiedPass, isFalse);
        expect(report.isVerifiedDescriptorRejection, isTrue);
      },
    );

    test(
      'valid PASS requires all valid-pass gates; does NOT require descriptorRejectedBeforeVulkanOk',
      () {
        final passReport = _createSamplePassReport();
        expect(passReport.isValidPass, isTrue);
        expect(passReport.descriptorRejectedBeforeVulkanOk, isFalse);

        for (final key
            in VGSingleCamIngestVulkanSpatialRenderSmokeReport
                .validPassGateKeys) {
          final failingGateReport = _createSamplePassReport({key: false});
          expect(failingGateReport.isValidPass, isFalse, reason: '$key failed');
          expect(
            failingGateReport.allNativeLanesPass,
            isFalse,
            reason: '$key failed',
          );
          expect(
            failingGateReport.isVerifiedPass,
            isFalse,
            reason: '$key failed',
          );
        }

        // Setting descriptorRejectedBeforeVulkanOk to true breaks valid pass
        final contradictoryReport = _createSamplePassReport({
          'descriptorRejectedBeforeVulkanOk': true,
        });
        expect(contradictoryReport.allNativeLanesPass, isFalse);
        expect(contradictoryReport.isVerifiedPass, isFalse);
      },
    );

    test('defensive fromMap handles non-map, null, or empty inputs', () {
      for (final invalid in <Object?>[null, 'not_a_map', 123, <int>[]]) {
        final report = VGSingleCamIngestVulkanSpatialRenderSmokeReport.fromMap(
          invalid,
        );
        expect(report.success, isFalse);
        expect(report.pass, isFalse);
        expect(report.isHarnessException, isTrue);
        expect(report.failureReason, equals('native_result_not_a_map'));
      }
    });

    test('factory constructors produce fail-shaped reports', () {
      final unsupported =
          VGSingleCamIngestVulkanSpatialRenderSmokeReport.unsupported(
            'device_not_supported',
            runId: 99,
          );
      expect(unsupported.success, isFalse);
      expect(unsupported.pass, isFalse);
      expect(unsupported.isUnsupported, isTrue);
      expect(unsupported.runId, equals(99));
      expect(unsupported.marker, equals(_failMarker));

      final harnessFail =
          VGSingleCamIngestVulkanSpatialRenderSmokeReport.harnessFailure(
            'timeout_error',
            runId: 101,
          );
      expect(harnessFail.success, isFalse);
      expect(harnessFail.isHarnessException, isTrue);
      expect(harnessFail.runId, equals(101));

      final malformed =
          VGSingleCamIngestVulkanSpatialRenderSmokeReport.malformedDescriptorShape(
            'missing_keys',
          );
      expect(malformed.success, isFalse);
      expect(malformed.isMalformedDescriptorShape, isTrue);
      expect(malformed.pass, isFalse);
    });
  });

  group('value semantics', () {
    test('equal reports compare equal and have matching hashCodes', () {
      final a = _createSamplePassReport();
      final b = _createSamplePassReport();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('runId: 42'));
    });

    test('reports differing in any field compare unequal', () {
      final base = _createSamplePassReport();
      final diffs = <Map<String, Object?>>[
        {'success': false, 'decision': 'nativeRenderFailed'},
        {'runId': 99},
        {'opened': false},
        {'selectedWidth': 1280},
        {'vulkanSetupOk': false},
        {'failureReason': 'failed'},
        {'proofBoundary': 'different'},
      ];
      for (final diff in diffs) {
        final variant = _createSamplePassReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group('start MethodChannel and descriptor shape validation', () {
    test(
      'start invokes channel with freeFloating PiP descriptor primitives',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel('test_single_cam_vulkan_start_pip');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return <String, Object?>{'started': true, 'runId': 55};
        });

        final descriptor =
            VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip()
                .toMap();
        final result =
            await VGSingleCamIngestVulkanSpatialRenderSmokeReport.startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
              descriptor: descriptor,
              channel: channel,
            );

        expect(capturedCall, isNotNull);
        expect(capturedCall!.method, equals(_startMethod));
        expect(result.runId, equals(55));
        expect(result.maxWidth, equals(640));
        expect(result.maxHeight, equals(480));

        final args = capturedCall!.arguments as Map;
        expect(args['maxWidth'], equals(640));
        expect(args['maxHeight'], equals(480));
        expect(args['timeoutMs'], equals(10000));
        expect(args['descriptor'], equals(descriptor));
      },
    );

    test(
      'start invokes channel with leftRight split descriptor primitives',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel('test_single_cam_vulkan_start_split');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return <String, Object?>{'started': true, 'runId': 56};
        });

        final descriptor =
            VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit()
                .toMap();
        final result =
            await VGSingleCamIngestVulkanSpatialRenderSmokeReport.startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
              descriptor: descriptor,
              maxWidth: 1280,
              maxHeight: 720,
              timeout: const Duration(seconds: 5),
              channel: channel,
            );

        expect(capturedCall, isNotNull);
        expect(result.runId, equals(56));
        expect(result.maxWidth, equals(1280));
        expect(result.maxHeight, equals(720));

        final args = capturedCall!.arguments as Map;
        expect(args['maxWidth'], equals(1280));
        expect(args['maxHeight'], equals(720));
        expect(args['timeoutMs'], equals(5000));
        expect(args['descriptor'], equals(descriptor));
      },
    );

    test(
      'method argument map exactly carries descriptor primitives (no opacity/cornerRadius)',
      () async {
        MethodCall? capturedCall;
        const channel = MethodChannel('test_single_cam_vulkan_primitives');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return <String, Object?>{'started': true, 'runId': 1};
        });

        final descriptor =
            VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip()
                .toMap();
        await VGSingleCamIngestVulkanSpatialRenderSmokeReport.startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
          descriptor: descriptor,
          channel: channel,
        );

        expect(capturedCall, isNotNull);
        final descArgs = (capturedCall!.arguments as Map)['descriptor'] as Map;
        expect(descArgs.containsKey('layoutMode'), isTrue);
        expect(descArgs.containsKey('pipAnchor'), isTrue);
        expect(descArgs.containsKey('pipCenterX'), isTrue);
        expect(descArgs.containsKey('pipCenterY'), isTrue);
        expect(descArgs.containsKey('pipWidthFraction'), isTrue);
        expect(descArgs.containsKey('pipAspectRatio'), isTrue);
        expect(descArgs.containsKey('pipMarginFraction'), isTrue);
        expect(descArgs.containsKey('splitDirection'), isTrue);
        expect(descArgs.containsKey('splitRatio'), isTrue);

        expect(descArgs.containsKey('cornerRadius'), isFalse);
        expect(descArgs.containsKey('opacity'), isFalse);
        expect(descArgs.containsKey('secondaryOpacity'), isFalse);
      },
    );

    test(
      'malformed descriptor shape fails before invoking method channel',
      () async {
        var channelCallCount = 0;
        const channel = MethodChannel('test_single_cam_vulkan_malformed_shape');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          channelCallCount++;
          return <String, Object?>{'started': true, 'runId': 1};
        });

        final malformedDescriptors = <Map<String, Object?>>[
          // Missing fields
          <String, Object?>{'layoutMode': 'pip'},
          <String, Object?>{
            'layoutMode': 'pip',
            'pipAnchor': 'freeFloating',
            // missing splitDirection, etc.
          },
          // Wrong types
          <String, Object?>{
            'layoutMode': 123, // should be String
            'pipAnchor': 'freeFloating',
            'splitDirection': 'topBottom',
            'pipCenterX': 0.5,
            'pipCenterY': 0.5,
            'pipWidthFraction': 0.3,
            'pipAspectRatio': 1.0,
            'pipMarginFraction': 0.05,
            'splitRatio': 0.5,
          },
          <String, Object?>{
            'layoutMode': 'pip',
            'pipAnchor': 'freeFloating',
            'splitDirection': 'topBottom',
            'pipCenterX': 'not_a_number', // should be num
            'pipCenterY': 0.5,
            'pipWidthFraction': 0.3,
            'pipAspectRatio': 1.0,
            'pipMarginFraction': 0.05,
            'splitRatio': 0.5,
          },
        ];

        for (final malformed in malformedDescriptors) {
          expect(
            () =>
                VGSingleCamIngestVulkanSpatialRenderSmokeReport.startAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
                  descriptor: malformed,
                  channel: channel,
                ),
            throwsA(isA<ArgumentError>()),
          );
        }
        expect(
          channelCallCount,
          equals(0),
          reason: 'Channel must never be invoked',
        );
      },
    );
  });

  group('dispose MethodChannel and idempotency', () {
    test(
      'missing runId throws ArgumentError before channel invocation',
      () async {
        var channelCalled = false;
        const channel = MethodChannel('test_single_cam_vulkan_dispose_null');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          channelCalled = true;
          return <String, Object?>{'pass': true};
        });

        expect(
          () =>
              VGSingleCamIngestVulkanSpatialRenderSmokeReport.disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
                runId: null,
                channel: channel,
              ),
          throwsA(isA<ArgumentError>()),
        );
        expect(channelCalled, isFalse);
      },
    );

    test('valid runId invokes dispose and is idempotent', () async {
      MethodCall? capturedCall;
      var disposeCalls = 0;
      const channel = MethodChannel('test_single_cam_vulkan_dispose_valid');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        capturedCall = call;
        disposeCalls++;
        return <String, Object?>{
          'pass': true,
          'runId': call.arguments['runId'],
          'raw': 'status=OK;runId=${call.arguments['runId']}',
        };
      });

      final res1 =
          await VGSingleCamIngestVulkanSpatialRenderSmokeReport.disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
            runId: 42,
            channel: channel,
          );
      expect(res1, isTrue);
      expect(capturedCall?.method, equals(_disposeMethod));
      expect(capturedCall?.arguments, equals({'runId': 42}));

      // Call second time with same runId (idempotent)
      final res2 =
          await VGSingleCamIngestVulkanSpatialRenderSmokeReport.disposeAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
            runId: 42,
            channel: channel,
          );
      expect(res2, isTrue);
      expect(disposeCalls, equals(2));
    });
  });

  group('runner execution & callback handling', () {
    test(
      'valid PiP start + completion callback yields verified pass report',
      () async {
        const channel = MethodChannel('test_single_cam_vulkan_run_pip');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == _startMethod) {
            // Simulate native background execution and completion callback
            scheduleMicrotask(() async {
              await binaryMessenger.handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall(
                    _callbackMethod,
                    _createSamplePassRawMap({'runId': 101}),
                  ),
                ),
                (_) {},
              );
            });
            return <String, Object?>{'started': true, 'runId': 101};
          }
          if (call.method == _disposeMethod) {
            return <String, Object?>{'pass': true, 'runId': 101};
          }
          return null;
        });

        final report =
            await VGSingleCamIngestVulkanSpatialRenderSmokeReport.runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
              descriptor:
                  VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
              channel: channel,
            );

        expect(report.isVerifiedPass, isTrue);
        expect(report.runId, equals(101));
        expect(report.descriptorParseOk, isTrue);
        expect(report.vulkanSetupOk, isTrue);
        expect(report.cameraImportOk, isTrue);
      },
    );

    test(
      'valid split start + completion callback yields verified pass report',
      () async {
        const channel = MethodChannel('test_single_cam_vulkan_run_split');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == _startMethod) {
            scheduleMicrotask(() async {
              await binaryMessenger.handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall(
                    _callbackMethod,
                    _createSamplePassRawMap({
                      'runId': 102,
                      'details': <String, Object?>{
                        'layoutModeResolved': 'splitScreen',
                        'splitDirectionResolved': 'leftRight',
                        'rejectionReason': '',
                      },
                    }),
                  ),
                ),
                (_) {},
              );
            });
            return <String, Object?>{'started': true, 'runId': 102};
          }
          if (call.method == _disposeMethod) {
            return <String, Object?>{'pass': true, 'runId': 102};
          }
          return null;
        });

        final report =
            await VGSingleCamIngestVulkanSpatialRenderSmokeReport.runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
              descriptor:
                  VGMultiCamDynamicDescriptorSpatialRenderInput.leftRightSplit(),
              channel: channel,
            );

        expect(report.isVerifiedPass, isTrue);
        expect(report.runId, equals(102));
        expect(report.layoutModeResolved, equals('splitScreen'));
        expect(report.splitDirectionResolved, equals('leftRight'));
      },
    );

    test(
      'raw malformed native descriptor rejection invokes channel and fails closed at render stage',
      () async {
        const channel = MethodChannel(
          'test_single_cam_vulkan_run_raw_rejection',
        );
        var startInvoked = false;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == _startMethod) {
            startInvoked = true;
            scheduleMicrotask(() async {
              await binaryMessenger.handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall(
                    _callbackMethod,
                    _createSampleRejectionRawMap({'runId': 103}),
                  ),
                ),
                (_) {},
              );
            });
            return <String, Object?>{'started': true, 'runId': 103};
          }
          if (call.method == _disposeMethod) {
            return <String, Object?>{'pass': true, 'runId': 103};
          }
          return null;
        });

        const rawDescriptorWithBadMode = <String, Object?>{
          'layoutMode': 'invalidLayoutMode',
          'pipAnchor': 'freeFloating',
          'pipCenterX': 0.5,
          'pipCenterY': 0.5,
          'pipWidthFraction': 0.3,
          'pipAspectRatio': 1.0,
          'pipMarginFraction': 0.05,
          'splitDirection': 'topBottom',
          'splitRatio': 0.5,
        };

        final report =
            await VGSingleCamIngestVulkanSpatialRenderSmokeReport.runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmokeWithRawDescriptor(
              rawDescriptorWithBadMode,
              channel: channel,
            );

        expect(startInvoked, isTrue);
        expect(report.isDescriptorRejected, isTrue);
        expect(report.isVerifiedDescriptorRejection, isTrue);
        expect(report.pass, isFalse);
        expect(report.descriptorParseOk, isFalse);
        expect(report.descriptorRejectedBeforeVulkanOk, isTrue);
      },
    );

    test(
      'runner with shape-malformed descriptor fails closed before invoking method channel',
      () async {
        var channelInvoked = false;
        const channel = MethodChannel(
          'test_single_cam_vulkan_run_shape_malformed',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          channelInvoked = true;
          return null;
        });

        const shapeMalformed = <String, Object?>{
          'layoutMode': 'pip',
          // missing all other required fields
        };

        final report =
            await VGSingleCamIngestVulkanSpatialRenderSmokeReport.runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmokeWithRawDescriptor(
              shapeMalformed,
              channel: channel,
            );

        expect(channelInvoked, isFalse);
        expect(report.isMalformedDescriptorShape, isTrue);
        expect(report.success, isFalse);
        expect(report.pass, isFalse);
        expect(report.reasons, contains('malformed_descriptor_shape'));
      },
    );

    test('unsupported status returns unsupported report', () async {
      const channel = MethodChannel('test_single_cam_vulkan_run_unsupported');
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == _startMethod) {
          scheduleMicrotask(() async {
            await binaryMessenger.handlePlatformMessage(
              channel.name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall(_callbackMethod, <String, Object?>{
                  'success': false,
                  'pass': false,
                  'status': 'UNSUPPORTED',
                  'decision': 'nativeUnsupported',
                  'marker': _failMarker,
                  'proofBoundary': _proofBoundary,
                  'failureReason': 'vulkan_unsupported',
                  'reasons': <String>['vulkan_unsupported'],
                  'runId': 104,
                  for (final key in _gateKeys) key: false,
                  'details': <String, Object?>{'vulkanUnsupported': true},
                }),
              ),
              (_) {},
            );
          });
          return <String, Object?>{'started': true, 'runId': 104};
        }
        if (call.method == _disposeMethod) {
          return <String, Object?>{'pass': true, 'runId': 104};
        }
        return null;
      });

      final report =
          await VGSingleCamIngestVulkanSpatialRenderSmokeReport.runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
            descriptor:
                VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
            channel: channel,
          );

      expect(report.isUnsupported, isTrue);
      expect(report.pass, isFalse);
      expect(report.vulkanSetupOk, isFalse);
    });

    test(
      'exception mapping handles PlatformException and MissingPluginException',
      () async {
        const unsupportedChannel = MethodChannel(
          'test_single_cam_vulkan_exc_unsupp',
        );
        binaryMessenger.setMockMethodCallHandler(unsupportedChannel, (
          call,
        ) async {
          throw PlatformException(
            code: 'UNSUPPORTED',
            message: 'Vulkan missing',
          );
        });

        final unsuppReport =
            await VGSingleCamIngestVulkanSpatialRenderSmokeReport.runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
              descriptor:
                  VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
              channel: unsupportedChannel,
            );
        expect(unsuppReport.isUnsupported, isTrue);

        const failedChannel = MethodChannel(
          'test_single_cam_vulkan_exc_failed',
        );
        binaryMessenger.setMockMethodCallHandler(failedChannel, (call) async {
          throw PlatformException(code: 'ERROR', message: 'Something exploded');
        });

        final failedReport =
            await VGSingleCamIngestVulkanSpatialRenderSmokeReport.runAndroidDagPhase3SingleCamIngestVulkanSpatialRenderSmoke(
              descriptor:
                  VGMultiCamDynamicDescriptorSpatialRenderInput.freeFloatingPip(),
              channel: failedChannel,
            );
        expect(failedReport.isHarnessException, isTrue);
        expect(failedReport.pass, isFalse);
      },
    );
  });
}
