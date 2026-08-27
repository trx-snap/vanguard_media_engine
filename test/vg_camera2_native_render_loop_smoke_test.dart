// vg_camera2_native_render_loop_smoke_test.dart
// vanguard_media_engine — Phase 3-Unit L: Android Camera2 PRIVATE ImageReader
// HardwareBuffer multi-frame native-render loop smoke foundation Dart model & MethodChannel contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'success': true,
  'apiLevel': 34,
  'hasCameraPermission': true,
  'attemptedOpen': true,
  'opened': true,
  'sessionConfigured': true,
  'repeatingStarted': true,
  'cameraId': '0',
  'selectedLensFacing': 'back',
  'selectedWidth': 640,
  'selectedHeight': 480,
  'imageFormatName': 'PRIVATE',
  'targetFrameCount': 5,
  'renderedFrames': 5,
  'hardwareBufferFrameCount': 5,
  'hardwareBufferClosedCount': 5,
  'imageClosedCount': 5,
  'syncFenceAwaitedCount': 5,
  'syncFenceClosedCount': 5,
  'firstFrameTimestampNs': 1000000000,
  'lastFrameTimestampNs': 1000133333,
  'monotonicFrameTimestamps': true,
  'nativeRenderRawFrames': const [
    'status=PASS;durationMs=10;renderedFrames=1;',
    'status=PASS;durationMs=10;renderedFrames=2;',
    'status=PASS;durationMs=10;renderedFrames=3;',
    'status=PASS;durationMs=10;renderedFrames=4;',
    'status=PASS;durationMs=10;renderedFrames=5;',
  ],
  'finalNativeRenderRaw': 'status=PASS;durationMs=10;renderedFrames=5;',
  'sessionClosed': true,
  'deviceClosed': true,
  'imageReaderClosed': true,
  'nativeSessionCreated': true,
  'nativeSessionDestroyed': true,
  'outputSurfaceReleased': true,
  'surfaceTextureReleased': true,
  'decision': 'nativeRenderLoopPassed',
  'reasons': const <String>[],
  'events': const [
    'openCameraRequested',
    'onOpened',
    'createCaptureSessionRequested',
    'onConfigured',
    'repeatingRequestStarted',
    'nativeRenderAttempted:frameIndex=0',
    'nativeRenderPassed:renderedFrames=1',
    'nativeRenderAttempted:frameIndex=1',
    'nativeRenderPassed:renderedFrames=2',
    'nativeRenderAttempted:frameIndex=2',
    'nativeRenderPassed:renderedFrames=3',
    'nativeRenderAttempted:frameIndex=3',
    'nativeRenderPassed:renderedFrames=4',
    'nativeRenderAttempted:frameIndex=4',
    'nativeRenderPassed:renderedFrames=5',
    'onSessionClosed',
    'onDeviceClosed',
  ],
  'diagnostics': const {'testKey': 'testVal'},
  'durationMs': 320,
  if (overrides != null) ...overrides,
};

VGCamera2NativeRenderLoopSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGCamera2NativeRenderLoopSmokeReport.fromMap(
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

  group('VGCamera2NativeRenderLoopSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 18 values in order', () {
      expect(
        VGCamera2NativeRenderLoopSmokeDecision.values,
        orderedEquals(const [
          VGCamera2NativeRenderLoopSmokeDecision.nativeRenderLoopPassed,
          VGCamera2NativeRenderLoopSmokeDecision.apiUnsupported,
          VGCamera2NativeRenderLoopSmokeDecision.nativeSessionFailed,
          VGCamera2NativeRenderLoopSmokeDecision.permissionRequired,
          VGCamera2NativeRenderLoopSmokeDecision.noCamera,
          VGCamera2NativeRenderLoopSmokeDecision.cameraManagerUnavailable,
          VGCamera2NativeRenderLoopSmokeDecision.cameraUnavailable,
          VGCamera2NativeRenderLoopSmokeDecision.unsupportedStream,
          VGCamera2NativeRenderLoopSmokeDecision.hardwareBufferUnavailable,
          VGCamera2NativeRenderLoopSmokeDecision.openDisconnected,
          VGCamera2NativeRenderLoopSmokeDecision.openError,
          VGCamera2NativeRenderLoopSmokeDecision.openTimeout,
          VGCamera2NativeRenderLoopSmokeDecision.sessionConfigureFailed,
          VGCamera2NativeRenderLoopSmokeDecision.sessionConfigureTimeout,
          VGCamera2NativeRenderLoopSmokeDecision.repeatingRequestFailed,
          VGCamera2NativeRenderLoopSmokeDecision.frameTimeout,
          VGCamera2NativeRenderLoopSmokeDecision.nativeRenderFailed,
          VGCamera2NativeRenderLoopSmokeDecision.captureFailed,
        ]),
      );
      expect(VGCamera2NativeRenderLoopSmokeDecision.values.length, equals(18));
    });

    test('fromRaw maps all known valid decision strings', () {
      for (final value in VGCamera2NativeRenderLoopSmokeDecision.values) {
        expect(
          VGCamera2NativeRenderLoopSmokeDecision.fromRaw(value.name),
          equals(value),
        );
      }
    });

    test(
      'fromRaw falls back to captureFailed for unknown, non-string, or null values',
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
            VGCamera2NativeRenderLoopSmokeDecision.fromRaw(invalid),
            equals(VGCamera2NativeRenderLoopSmokeDecision.captureFailed),
          );
        }
      },
    );
  });

  group('VGCamera2NativeRenderLoopSmokeReport fromMap and toMap', () {
    test(
      'nativeRenderLoopPassed decision report parses and round-trips all fields cleanly',
      () {
        final report = VGCamera2NativeRenderLoopSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.success, isTrue);
        expect(report.apiLevel, equals(34));
        expect(report.hasCameraPermission, isTrue);
        expect(report.attemptedOpen, isTrue);
        expect(report.opened, isTrue);
        expect(report.sessionConfigured, isTrue);
        expect(report.repeatingStarted, isTrue);
        expect(report.cameraId, equals('0'));
        expect(report.selectedLensFacing, equals('back'));
        expect(report.selectedWidth, equals(640));
        expect(report.selectedHeight, equals(480));
        expect(report.imageFormatName, equals('PRIVATE'));
        expect(report.targetFrameCount, equals(5));
        expect(report.renderedFrames, equals(5));
        expect(report.hardwareBufferFrameCount, equals(5));
        expect(report.hardwareBufferClosedCount, equals(5));
        expect(report.imageClosedCount, equals(5));
        expect(report.syncFenceAwaitedCount, equals(5));
        expect(report.syncFenceClosedCount, equals(5));
        expect(report.firstFrameTimestampNs, equals(1000000000));
        expect(report.lastFrameTimestampNs, equals(1000133333));
        expect(report.monotonicFrameTimestamps, isTrue);
        expect(report.nativeRenderRawFrames.length, equals(5));
        expect(
          report.finalNativeRenderRaw,
          equals('status=PASS;durationMs=10;renderedFrames=5;'),
        );
        expect(report.sessionClosed, isTrue);
        expect(report.deviceClosed, isTrue);
        expect(report.imageReaderClosed, isTrue);
        expect(report.nativeSessionCreated, isTrue);
        expect(report.nativeSessionDestroyed, isTrue);
        expect(report.outputSurfaceReleased, isTrue);
        expect(report.surfaceTextureReleased, isTrue);
        expect(
          report.decision,
          equals(VGCamera2NativeRenderLoopSmokeDecision.nativeRenderLoopPassed),
        );
        expect(report.reasons, isEmpty);
        expect(report.events.length, equals(17));
        expect(report.diagnostics, equals({'testKey': 'testVal'}));
        expect(report.durationMs, equals(320));

        expect(report.isPermissionRequired, isFalse);
        expect(report.isNativeRenderLoopPassed, isTrue);
        expect(report.isAttempted, isTrue);
        expect(report.completedTargetFrames, isTrue);
        expect(report.isCleanedUp, isTrue);

        final serialized = report.toMap();
        expect(serialized['success'], isTrue);
        expect(serialized['targetFrameCount'], equals(5));
        expect(serialized['renderedFrames'], equals(5));
        expect(serialized['hardwareBufferFrameCount'], equals(5));
        expect(serialized['hardwareBufferClosedCount'], equals(5));
        expect(serialized['imageClosedCount'], equals(5));
        expect(serialized['syncFenceAwaitedCount'], equals(5));
        expect(serialized['syncFenceClosedCount'], equals(5));
        expect(serialized['firstFrameTimestampNs'], equals(1000000000));
        expect(serialized['lastFrameTimestampNs'], equals(1000133333));
        expect(serialized['monotonicFrameTimestamps'], isTrue);
        expect(
          serialized['nativeRenderRawFrames'],
          equals(report.nativeRenderRawFrames),
        );
        expect(
          serialized['finalNativeRenderRaw'],
          equals('status=PASS;durationMs=10;renderedFrames=5;'),
        );
        expect(serialized['sessionClosed'], isTrue);
        expect(serialized['deviceClosed'], isTrue);
        expect(serialized['imageReaderClosed'], isTrue);
        expect(serialized['nativeSessionCreated'], isTrue);
        expect(serialized['nativeSessionDestroyed'], isTrue);
        expect(serialized['outputSurfaceReleased'], isTrue);
        expect(serialized['surfaceTextureReleased'], isTrue);
        expect(serialized['decision'], equals('nativeRenderLoopPassed'));
        expect(serialized['events'], equals(report.events));
        expect(serialized['diagnostics'], equals(report.diagnostics));

        final roundTrip = VGCamera2NativeRenderLoopSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('lifecycle failure decisions parse coherently', () {
      void check(
        VGCamera2NativeRenderLoopSmokeDecision d,
        List<String> r, {
        bool att = true,
        bool cln = true,
        Map<String, Object?> ov = const {},
      }) {
        final report = VGCamera2NativeRenderLoopSmokeReport.fromMap(
          _createSampleRawMap({
            'success': false,
            'attemptedOpen': att,
            'opened': att,
            'sessionConfigured': att,
            'repeatingStarted': att,
            'renderedFrames': 0,
            'hardwareBufferFrameCount': 0,
            'hardwareBufferClosedCount': 0,
            'imageClosedCount': 0,
            'syncFenceAwaitedCount': 0,
            'syncFenceClosedCount': 0,
            'firstFrameTimestampNs': null,
            'lastFrameTimestampNs': null,
            'nativeRenderRawFrames': const <String>[],
            'finalNativeRenderRaw': null,
            'sessionClosed': cln,
            'deviceClosed': cln,
            'imageReaderClosed': cln,
            'nativeSessionCreated': att,
            'nativeSessionDestroyed': cln,
            'outputSurfaceReleased': cln,
            'surfaceTextureReleased': cln,
            'decision': d.name,
            'reasons': r,
            ...ov,
          }),
        );
        expect(report.decision, equals(d));
        expect(report.reasons, equals(r));
        expect(report.isAttempted, equals(att));
        expect(report.isCleanedUp, equals(cln));
      }

      check(
        VGCamera2NativeRenderLoopSmokeDecision.apiUnsupported,
        const ['api_below_29'],
        att: false,
        cln: false,
        ov: const {
          'apiLevel': 28,
          'cameraId': null,
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.nativeSessionFailed,
        const ['native_session_create_failed'],
        att: false,
        cln: false,
        ov: const {
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'diagnostics': {'nativeCreateResult': 'status=ERROR;'},
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.permissionRequired,
        const ['camera_permission_absent'],
        att: false,
        cln: false,
        ov: const {
          'hasCameraPermission': false,
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.noCamera,
        const ['no_camera_available'],
        att: false,
        cln: false,
        ov: const {
          'cameraId': null,
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.cameraManagerUnavailable,
        const ['camera_manager_unavailable'],
        att: false,
        cln: false,
        ov: const {
          'cameraId': null,
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.cameraUnavailable,
        const ['requested_camera_id_not_found'],
        att: false,
        cln: false,
        ov: const {
          'cameraId': '99',
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.unsupportedStream,
        const ['no_private_output_sizes'],
        att: false,
        cln: false,
        ov: const {
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.hardwareBufferUnavailable,
        const ['hardware_buffer_unavailable'],
        ov: const {'hardwareBufferFrameCount': 0},
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.openDisconnected,
        const ['camera_disconnected'],
        cln: false,
        ov: const {'opened': false, 'sessionClosed': false},
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.openError,
        const ['camera_open_error'],
        cln: false,
        ov: const {
          'opened': false,
          'sessionClosed': false,
          'diagnostics': {'errorCode': 3},
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.openTimeout,
        const ['camera_open_timeout'],
        cln: false,
        ov: const {
          'opened': false,
          'sessionClosed': false,
          'deviceClosed': false,
          'durationMs': 10002,
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.sessionConfigureFailed,
        const ['session_configure_failed'],
        cln: false,
        ov: const {'sessionConfigured': false, 'sessionClosed': false},
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.sessionConfigureTimeout,
        const ['session_configure_timeout'],
        cln: false,
        ov: const {
          'sessionConfigured': false,
          'sessionClosed': false,
          'durationMs': 10100,
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.repeatingRequestFailed,
        const ['repeating_request_failed'],
        ov: const {
          'repeatingStarted': false,
          'diagnostics': {'setRepeatingRequestError': 'CameraAccessException'},
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.frameTimeout,
        const ['frame_timeout'],
        ov: const {'renderedFrames': 2, 'durationMs': 10200},
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.nativeRenderFailed,
        const ['native_render_failed'],
        ov: const {
          'renderedFrames': 1,
          'finalNativeRenderRaw':
              'status=FAIL;error=SHADER_COMPILATION_FAILED;',
          'diagnostics': {
            'nativeRenderResult':
                'status=FAIL;error=SHADER_COMPILATION_FAILED;',
          },
        },
      );
      check(
        VGCamera2NativeRenderLoopSmokeDecision.captureFailed,
        const ['capture_failed'],
        ov: const {
          'diagnostics': {'captureFailureReason': 1},
          'durationMs': 400,
        },
      );
    });

    test(
      'fromMap handles malformed non-map inputs by preserving raw in diagnostics and using reason native_result_not_a_map',
      () {
        for (final invalid in [
          null,
          'not_a_map',
          999,
          <Object?>['a', 'b'],
        ]) {
          final report = VGCamera2NativeRenderLoopSmokeReport.fromMap(invalid);
          expect(report.success, isFalse);
          expect(report.apiLevel, equals(0));
          expect(report.cameraId, isNull);
          expect(report.selectedLensFacing, equals('unknown'));
          expect(report.imageFormatName, equals('PRIVATE'));
          expect(report.targetFrameCount, equals(0));
          expect(report.renderedFrames, equals(0));
          expect(report.nativeRenderRawFrames, isEmpty);
          expect(report.finalNativeRenderRaw, isNull);
          expect(
            report.decision,
            equals(VGCamera2NativeRenderLoopSmokeDecision.captureFailed),
          );
          expect(
            report.reasons,
            equals(const <String>['native_result_not_a_map']),
          );
          expect(report.events, isEmpty);
          expect(report.diagnostics, equals(<String, Object?>{'raw': invalid}));
          expect(report.durationMs, equals(0));
        }
      },
    );

    test(
      'fromMap handles missing/malformed list/map fields defensively producing safe defaults',
      () {
        final report = VGCamera2NativeRenderLoopSmokeReport.fromMap({
          for (final key in _createSampleRawMap().keys) key: null,
        });
        expect(
          report,
          equals(
            const VGCamera2NativeRenderLoopSmokeReport(
              success: false,
              apiLevel: 0,
              hasCameraPermission: false,
              attemptedOpen: false,
              opened: false,
              sessionConfigured: false,
              repeatingStarted: false,
              cameraId: null,
              selectedLensFacing: 'unknown',
              selectedWidth: 0,
              selectedHeight: 0,
              imageFormatName: 'PRIVATE',
              targetFrameCount: 0,
              renderedFrames: 0,
              hardwareBufferFrameCount: 0,
              hardwareBufferClosedCount: 0,
              imageClosedCount: 0,
              syncFenceAwaitedCount: 0,
              syncFenceClosedCount: 0,
              firstFrameTimestampNs: null,
              lastFrameTimestampNs: null,
              monotonicFrameTimestamps: true,
              nativeRenderRawFrames: [],
              finalNativeRenderRaw: null,
              sessionClosed: false,
              deviceClosed: false,
              imageReaderClosed: false,
              nativeSessionCreated: false,
              nativeSessionDestroyed: false,
              outputSurfaceReleased: false,
              surfaceTextureReleased: false,
              decision: VGCamera2NativeRenderLoopSmokeDecision.captureFailed,
              reasons: [],
              events: [],
              diagnostics: {},
              durationMs: 0,
            ),
          ),
        );

        final parsed = VGCamera2NativeRenderLoopSmokeReport.fromMap({
          'success': true,
          'apiLevel': 34.0,
          'selectedWidth': 640.0,
          'selectedHeight': 480.0,
          'targetFrameCount': 5.0,
          'renderedFrames': 5.0,
          'hardwareBufferFrameCount': 5.0,
          'hardwareBufferClosedCount': 5.0,
          'imageClosedCount': 5.0,
          'syncFenceAwaitedCount': 5.0,
          'syncFenceClosedCount': 5.0,
          'firstFrameTimestampNs': 1000000000.0,
          'lastFrameTimestampNs': 1000133333.0,
          'durationMs': 250.0,
          'nativeRenderRawFrames': <Object?>['status=PASS;frame=0', 123, null],
          'reasons': <Object?>['r1', 123, null],
          'events': <Object?>['e1', 456],
          'diagnostics': <Object?, Object?>{'nested': 'ok'},
        });
        expect(parsed.apiLevel, equals(34));
        expect(parsed.selectedWidth, equals(640));
        expect(parsed.selectedHeight, equals(480));
        expect(parsed.targetFrameCount, equals(5));
        expect(parsed.renderedFrames, equals(5));
        expect(parsed.hardwareBufferFrameCount, equals(5));
        expect(parsed.hardwareBufferClosedCount, equals(5));
        expect(parsed.imageClosedCount, equals(5));
        expect(parsed.syncFenceAwaitedCount, equals(5));
        expect(parsed.syncFenceClosedCount, equals(5));
        expect(parsed.firstFrameTimestampNs, equals(1000000000));
        expect(parsed.lastFrameTimestampNs, equals(1000133333));
        expect(parsed.durationMs, equals(250));
        expect(
          parsed.nativeRenderRawFrames,
          equals(['status=PASS;frame=0', '123']),
        );
        expect(parsed.reasons, equals(['r1', '123']));
        expect(parsed.events, equals(['e1', '456']));
        expect(parsed.diagnostics, equals({'nested': 'ok'}));

        final parsedBad =
            VGCamera2NativeRenderLoopSmokeReport.fromMap(<Object?, Object?>{
              'nativeRenderRawFrames': 'not_a_list',
              'reasons': 'not_a_list',
              'events': 12345,
              'diagnostics': 'not_a_map',
            });
        expect(parsedBad.nativeRenderRawFrames, isEmpty);
        expect(parsedBad.reasons, isEmpty);
        expect(parsedBad.events, isEmpty);
        expect(parsedBad.diagnostics, isEmpty);
      },
    );
  });

  group('VGCamera2NativeRenderLoopSmokeReport getters', () {
    test('isPermissionRequired reflects decision strictly', () {
      expect(
        _createSampleReport({
          'decision': 'permissionRequired',
        }).isPermissionRequired,
        isTrue,
      );
      expect(
        _createSampleReport({
          'decision': 'nativeRenderLoopPassed',
        }).isPermissionRequired,
        isFalse,
      );
    });

    test('isNativeRenderLoopPassed reflects decision strictly', () {
      expect(
        _createSampleReport({
          'decision': 'nativeRenderLoopPassed',
        }).isNativeRenderLoopPassed,
        isTrue,
      );
      expect(
        _createSampleReport({
          'decision': 'nativeRenderFailed',
        }).isNativeRenderLoopPassed,
        isFalse,
      );
    });

    test('isAttempted mirrors attemptedOpen exactly', () {
      expect(_createSampleReport({'attemptedOpen': true}).isAttempted, isTrue);
      expect(
        _createSampleReport({'attemptedOpen': false}).isAttempted,
        isFalse,
      );
    });

    test('completedTargetFrames checks renderedFrames >= targetFrameCount', () {
      expect(
        _createSampleReport({
          'targetFrameCount': 5,
          'renderedFrames': 5,
        }).completedTargetFrames,
        isTrue,
      );
      expect(
        _createSampleReport({
          'targetFrameCount': 5,
          'renderedFrames': 6,
        }).completedTargetFrames,
        isTrue,
      );
      expect(
        _createSampleReport({
          'targetFrameCount': 5,
          'renderedFrames': 4,
        }).completedTargetFrames,
        isFalse,
      );
    });

    test(
      'isCleanedUp requires sessionClosed && deviceClosed && imageReaderClosed && nativeSessionDestroyed && outputSurfaceReleased && surfaceTextureReleased',
      () {
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isTrue,
        );
        expect(
          _createSampleReport({
            'sessionClosed': false,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': false,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': false,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': false,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': false,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': false,
          }).isCleanedUp,
          isFalse,
        );
      },
    );
  });

  group('VGCamera2NativeRenderLoopSmokeReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      for (final snippet in [
        'VGCamera2NativeRenderLoopSmokeReport(',
        'decision: VGCamera2NativeRenderLoopSmokeDecision.nativeRenderLoopPassed',
        'success: true',
        'apiLevel: 34',
        'cameraId: 0',
        'selectedWidth: 640',
        'selectedHeight: 480',
        'targetFrameCount: 5',
        'renderedFrames: 5',
        'hardwareBufferFrameCount: 5',
        'hardwareBufferClosedCount: 5',
        'imageClosedCount: 5',
        'syncFenceAwaitedCount: 5',
        'syncFenceClosedCount: 5',
        'nativeSessionCreated: true',
        'nativeSessionDestroyed: true',
        'outputSurfaceReleased: true',
        'surfaceTextureReleased: true',
        'firstFrameTimestampNs: 1000000000',
        'lastFrameTimestampNs: 1000133333',
        'monotonicFrameTimestamps: true',
        'finalNativeRenderRaw: status=PASS;durationMs=10;renderedFrames=5;',
        'durationMs: 320',
      ]) {
        expect(a.toString(), contains(snippet));
      }
    });

    test(
      'stable diagnostics hash produces equal hash and equality with different map key order',
      () {
        final report1 = _createSampleReport({
          'diagnostics': {'alpha': 1, 'beta': 2, 'gamma': 3},
        });
        final report2 = _createSampleReport({
          'diagnostics': {'gamma': 3, 'alpha': 1, 'beta': 2},
        });

        expect(report1, equals(report2));
        expect(report1.hashCode, equals(report2.hashCode));
      },
    );

    test('inequality when any single field differs', () {
      final base = _createSampleReport();
      const diffs = <Map<String, Object?>>[
        {'success': false},
        {'apiLevel': 33},
        {'hasCameraPermission': false},
        {'attemptedOpen': false},
        {'opened': false},
        {'sessionConfigured': false},
        {'repeatingStarted': false},
        {'cameraId': '1'},
        {'selectedLensFacing': 'front'},
        {'selectedWidth': 1280},
        {'selectedHeight': 720},
        {'imageFormatName': 'YUV_420_888'},
        {'targetFrameCount': 10},
        {'renderedFrames': 4},
        {'hardwareBufferFrameCount': 4},
        {'hardwareBufferClosedCount': 4},
        {'imageClosedCount': 4},
        {'syncFenceAwaitedCount': 0},
        {'syncFenceClosedCount': 0},
        {'firstFrameTimestampNs': 2000000000},
        {'lastFrameTimestampNs': 2000133333},
        {'monotonicFrameTimestamps': false},
        {
          'nativeRenderRawFrames': [
            'status=PASS;durationMs=10;renderedFrames=1;',
          ],
        },
        {'finalNativeRenderRaw': 'status=FAIL;'},
        {'sessionClosed': false},
        {'deviceClosed': false},
        {'imageReaderClosed': false},
        {'nativeSessionCreated': false},
        {'nativeSessionDestroyed': false},
        {'outputSurfaceReleased': false},
        {'surfaceTextureReleased': false},
        {'decision': 'nativeRenderFailed'},
        {
          'reasons': ['other_reason'],
        },
        {
          'events': ['other_event'],
        },
        {
          'diagnostics': {'other': 1},
        },
        {'durationMs': 999},
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group(
    'VGCamera2NativeRenderLoopSmokeReport.runAndroidCamera2NativeRenderLoopSmoke MethodChannel contract',
    () {
      Future<MethodCall> captureCall({
        required Future<VGCamera2NativeRenderLoopSmokeReport> Function(
          MethodChannel channel,
        )
        action,
        Map<String, Object?>? response,
      }) async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_vanguard_native_render_loop_contract',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return response ?? _createSampleRawMap();
        });
        await action(channel);
        return capturedCall!;
      }

      test(
        'invokes runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke with default args and omits null cameraId',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2NativeRenderLoopSmokeReport.runAndroidCamera2NativeRenderLoopSmoke(
                  channel: channel,
                ),
          );

          expect(
            call.method,
            equals('runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke'),
          );
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments.containsKey('cameraId'), isFalse);
          expect(arguments['timeoutMs'], equals(10000));
          expect(arguments['maxWidth'], equals(640));
          expect(arguments['maxHeight'], equals(480));
          expect(arguments['frameCount'], equals(5));
        },
      );

      test(
        'passes explicit nonblank cameraId, custom timeout, custom dimensions, and custom frameCount',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2NativeRenderLoopSmokeReport.runAndroidCamera2NativeRenderLoopSmoke(
                  cameraId: '1',
                  timeout: const Duration(seconds: 12),
                  maxWidth: 1280,
                  maxHeight: 720,
                  frameCount: 10,
                  channel: channel,
                ),
            response: _createSampleRawMap({
              'cameraId': '1',
              'selectedLensFacing': 'front',
              'selectedWidth': 1280,
              'selectedHeight': 720,
              'targetFrameCount': 10,
              'renderedFrames': 10,
            }),
          );

          expect(
            call.method,
            equals('runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke'),
          );
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['cameraId'], equals('1'));
          expect(arguments['timeoutMs'], equals(12000));
          expect(arguments['maxWidth'], equals(1280));
          expect(arguments['maxHeight'], equals(720));
          expect(arguments['frameCount'], equals(10));
        },
      );

      test('omits blank or whitespace-only cameraId', () async {
        final call = await captureCall(
          action: (channel) =>
              VGCamera2NativeRenderLoopSmokeReport.runAndroidCamera2NativeRenderLoopSmoke(
                cameraId: '   ',
                channel: channel,
              ),
        );

        final arguments = call.arguments as Map<Object?, Object?>;
        expect(arguments.containsKey('cameraId'), isFalse);
        expect(arguments['timeoutMs'], equals(10000));
        expect(arguments['maxWidth'], equals(640));
        expect(arguments['maxHeight'], equals(480));
        expect(arguments['frameCount'], equals(5));
      });

      test('uses default vanguard_media_engine channel when omitted', () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap({'durationMs': 160});
        });

        final report =
            await VGCamera2NativeRenderLoopSmokeReport.runAndroidCamera2NativeRenderLoopSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase3UnitLCameraNativeRenderLoopSmoke'),
        );
        expect(report.success, isTrue);
      });
    },
  );
}
