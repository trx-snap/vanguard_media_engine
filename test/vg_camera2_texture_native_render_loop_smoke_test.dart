// vg_camera2_texture_native_render_loop_smoke_test.dart
// vanguard_media_engine — Phase 3-Unit M: Android Camera2 PRIVATE ImageReader
// HardwareBuffer Flutter Texture Native Render Loop Smoke Foundation Dart model & MethodChannel contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'success': true,
  'started': true,
  'textureId': 42,
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
  'selectedSensorOrientationDegrees': 90,
  'renderedRotationDegrees': 90,
  'renderedMirrorHorizontal': false,
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
    'status=PASS;frameIndex=0;renderedFrames=1;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=1;renderedFrames=2;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=2;renderedFrames=3;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=3;renderedFrames=4;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=4;renderedFrames=5;generationId=100;renderResult=success;releaseResult=success',
  ],
  'finalNativeRenderRaw':
      'status=PASS;frameIndex=4;renderedFrames=5;generationId=100;renderResult=success;releaseResult=success',
  'nativeSessionCreated': true,
  'nativeGenerationId': 100,
  'nativeSessionDestroyed': true,
  'sessionClosed': true,
  'deviceClosed': true,
  'imageReaderClosed': true,
  'surfaceProducerReleased': false,
  'decision': 'textureNativeRenderLoopPassed',
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
  'durationMs': 350,
  if (overrides != null) ...overrides,
};

VGCamera2TextureNativeRenderLoopSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
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

  group('VGCamera2TextureNativeRenderLoopSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 20 values in order', () {
      expect(
        VGCamera2TextureNativeRenderLoopSmokeDecision.values,
        orderedEquals(const [
          VGCamera2TextureNativeRenderLoopSmokeDecision
              .textureNativeRenderLoopPassed,
          VGCamera2TextureNativeRenderLoopSmokeDecision.apiUnsupported,
          VGCamera2TextureNativeRenderLoopSmokeDecision.nativeSessionFailed,
          VGCamera2TextureNativeRenderLoopSmokeDecision.permissionRequired,
          VGCamera2TextureNativeRenderLoopSmokeDecision.noCamera,
          VGCamera2TextureNativeRenderLoopSmokeDecision
              .cameraManagerUnavailable,
          VGCamera2TextureNativeRenderLoopSmokeDecision.cameraUnavailable,
          VGCamera2TextureNativeRenderLoopSmokeDecision.unsupportedStream,
          VGCamera2TextureNativeRenderLoopSmokeDecision
              .hardwareBufferUnavailable,
          VGCamera2TextureNativeRenderLoopSmokeDecision.openDisconnected,
          VGCamera2TextureNativeRenderLoopSmokeDecision.openError,
          VGCamera2TextureNativeRenderLoopSmokeDecision.openTimeout,
          VGCamera2TextureNativeRenderLoopSmokeDecision.sessionConfigureFailed,
          VGCamera2TextureNativeRenderLoopSmokeDecision.sessionConfigureTimeout,
          VGCamera2TextureNativeRenderLoopSmokeDecision.repeatingRequestFailed,
          VGCamera2TextureNativeRenderLoopSmokeDecision.frameTimeout,
          VGCamera2TextureNativeRenderLoopSmokeDecision.nativeRenderFailed,
          VGCamera2TextureNativeRenderLoopSmokeDecision.captureFailed,
          VGCamera2TextureNativeRenderLoopSmokeDecision.disposed,
          VGCamera2TextureNativeRenderLoopSmokeDecision
              .invalidSensorOrientation,
        ]),
      );
      expect(
        VGCamera2TextureNativeRenderLoopSmokeDecision.values.length,
        equals(20),
      );
    });

    test('fromRaw maps all known valid decision strings', () {
      for (final value
          in VGCamera2TextureNativeRenderLoopSmokeDecision.values) {
        expect(
          VGCamera2TextureNativeRenderLoopSmokeDecision.fromRaw(value.name),
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
            VGCamera2TextureNativeRenderLoopSmokeDecision.fromRaw(invalid),
            equals(VGCamera2TextureNativeRenderLoopSmokeDecision.captureFailed),
          );
        }
      },
    );
  });

  group('VGCamera2TextureNativeRenderLoopSmokeReport fromMap and toMap', () {
    test(
      'textureNativeRenderLoopPassed decision report parses and round-trips all fields cleanly',
      () {
        final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.success, isTrue);
        expect(report.started, isTrue);
        expect(report.textureId, equals(42));
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
        expect(report.selectedSensorOrientationDegrees, equals(90));
        expect(report.renderedRotationDegrees, equals(90));
        expect(report.renderedMirrorHorizontal, isFalse);
        expect(report.hasExpectedRenderRotation, isTrue);
        expect(report.hasExpectedRenderMirror, isTrue);
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
          equals(
            'status=PASS;frameIndex=4;renderedFrames=5;generationId=100;renderResult=success;releaseResult=success',
          ),
        );
        expect(report.nativeSessionCreated, isTrue);
        expect(report.nativeGenerationId, equals(100));
        expect(report.nativeSessionDestroyed, isTrue);
        expect(report.sessionClosed, isTrue);
        expect(report.deviceClosed, isTrue);
        expect(report.imageReaderClosed, isTrue);
        expect(report.surfaceProducerReleased, isFalse);
        expect(
          report.decision,
          equals(
            VGCamera2TextureNativeRenderLoopSmokeDecision
                .textureNativeRenderLoopPassed,
          ),
        );
        expect(report.reasons, isEmpty);
        expect(report.events.length, equals(17));
        expect(report.diagnostics, equals({'testKey': 'testVal'}));
        expect(report.durationMs, equals(350));

        expect(report.isPermissionRequired, isFalse);
        expect(report.isTextureNativeRenderLoopPassed, isTrue);
        expect(report.isDisposed, isFalse);
        expect(report.isAttempted, isTrue);
        expect(report.completedTargetFrames, isTrue);
        expect(report.hasValidSensorOrientation, isTrue);
        expect(report.isCleanedUp, isTrue);

        final serialized = report.toMap();
        expect(serialized['success'], isTrue);
        expect(serialized['started'], isTrue);
        expect(serialized['textureId'], equals(42));
        expect(serialized['apiLevel'], equals(34));
        expect(serialized['hasCameraPermission'], isTrue);
        expect(serialized['attemptedOpen'], isTrue);
        expect(serialized['opened'], isTrue);
        expect(serialized['sessionConfigured'], isTrue);
        expect(serialized['repeatingStarted'], isTrue);
        expect(serialized['cameraId'], equals('0'));
        expect(serialized['selectedLensFacing'], equals('back'));
        expect(serialized['selectedWidth'], equals(640));
        expect(serialized['selectedHeight'], equals(480));
        expect(serialized['selectedSensorOrientationDegrees'], equals(90));
        expect(serialized['renderedRotationDegrees'], equals(90));
        expect(serialized['renderedMirrorHorizontal'], isFalse);
        expect(serialized['imageFormatName'], equals('PRIVATE'));
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
          equals(
            'status=PASS;frameIndex=4;renderedFrames=5;generationId=100;renderResult=success;releaseResult=success',
          ),
        );
        expect(serialized['nativeSessionCreated'], isTrue);
        expect(serialized['nativeGenerationId'], equals(100));
        expect(serialized['nativeSessionDestroyed'], isTrue);
        expect(serialized['sessionClosed'], isTrue);
        expect(serialized['deviceClosed'], isTrue);
        expect(serialized['imageReaderClosed'], isTrue);
        expect(serialized['surfaceProducerReleased'], isFalse);
        expect(serialized['decision'], equals('textureNativeRenderLoopPassed'));
        expect(serialized['events'], equals(report.events));
        expect(serialized['diagnostics'], equals(report.diagnostics));
        expect(serialized['durationMs'], equals(350));

        final roundTrip = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('lifecycle failure decisions parse coherently', () {
      void check(
        VGCamera2TextureNativeRenderLoopSmokeDecision d,
        List<String> r, {
        bool att = true,
        bool cln = true,
        Map<String, Object?> ov = const {},
      }) {
        final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
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
            'nativeGenerationId': att ? 100 : 0,
            'nativeSessionDestroyed': cln,
            'surfaceProducerReleased': false,
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
        VGCamera2TextureNativeRenderLoopSmokeDecision.apiUnsupported,
        const ['api_below_29'],
        att: false,
        cln: false,
        ov: const {
          'apiLevel': 28,
          'cameraId': null,
          'nativeSessionCreated': false,
          'nativeGenerationId': 0,
          'nativeSessionDestroyed': false,
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.nativeSessionFailed,
        const ['native_session_create_failed'],
        att: false,
        cln: false,
        ov: const {
          'nativeSessionCreated': false,
          'nativeGenerationId': 0,
          'nativeSessionDestroyed': false,
          'diagnostics': {'nativeCreateResult': 'status=ERROR;'},
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.permissionRequired,
        const ['camera_permission_absent'],
        att: false,
        cln: false,
        ov: const {
          'hasCameraPermission': false,
          'nativeSessionCreated': false,
          'nativeGenerationId': 0,
          'nativeSessionDestroyed': false,
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.noCamera,
        const ['no_camera_available'],
        att: false,
        cln: false,
        ov: const {
          'cameraId': null,
          'nativeSessionCreated': false,
          'nativeGenerationId': 0,
          'nativeSessionDestroyed': false,
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.cameraManagerUnavailable,
        const ['camera_manager_unavailable'],
        att: false,
        cln: false,
        ov: const {
          'cameraId': null,
          'nativeSessionCreated': false,
          'nativeGenerationId': 0,
          'nativeSessionDestroyed': false,
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.cameraUnavailable,
        const ['requested_camera_id_not_found'],
        att: false,
        cln: false,
        ov: const {
          'cameraId': '99',
          'nativeSessionCreated': false,
          'nativeGenerationId': 0,
          'nativeSessionDestroyed': false,
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.unsupportedStream,
        const ['no_private_output_sizes'],
        att: false,
        cln: false,
        ov: const {
          'nativeSessionCreated': false,
          'nativeGenerationId': 0,
          'nativeSessionDestroyed': false,
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.hardwareBufferUnavailable,
        const ['hardware_buffer_unavailable'],
        ov: const {'hardwareBufferFrameCount': 0},
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.openDisconnected,
        const ['camera_disconnected'],
        cln: false,
        ov: const {'opened': false, 'sessionClosed': false},
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.openError,
        const ['camera_open_error'],
        cln: false,
        ov: const {
          'opened': false,
          'sessionClosed': false,
          'diagnostics': {'errorCode': 3},
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.openTimeout,
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
        VGCamera2TextureNativeRenderLoopSmokeDecision.sessionConfigureFailed,
        const ['session_configure_failed'],
        cln: false,
        ov: const {'sessionConfigured': false, 'sessionClosed': false},
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.sessionConfigureTimeout,
        const ['session_configure_timeout'],
        cln: false,
        ov: const {
          'sessionConfigured': false,
          'sessionClosed': false,
          'durationMs': 10100,
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.repeatingRequestFailed,
        const ['repeating_request_failed'],
        ov: const {
          'repeatingStarted': false,
          'diagnostics': {'setRepeatingRequestError': 'CameraAccessException'},
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.frameTimeout,
        const ['frame_timeout'],
        ov: const {'renderedFrames': 2, 'durationMs': 10200},
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.nativeRenderFailed,
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
        VGCamera2TextureNativeRenderLoopSmokeDecision.captureFailed,
        const ['capture_failed'],
        ov: const {
          'diagnostics': {'captureFailureReason': 1},
          'durationMs': 400,
        },
      );
      check(
        VGCamera2TextureNativeRenderLoopSmokeDecision.disposed,
        const ['disposed_during_run'],
        ov: const {'surfaceProducerReleased': false},
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
          final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            invalid,
          );
          expect(report.success, isFalse);
          expect(report.started, isFalse);
          expect(report.textureId, equals(-1));
          expect(report.apiLevel, equals(0));
          expect(report.hasCameraPermission, isFalse);
          expect(report.attemptedOpen, isFalse);
          expect(report.opened, isFalse);
          expect(report.sessionConfigured, isFalse);
          expect(report.repeatingStarted, isFalse);
          expect(report.cameraId, isNull);
          expect(report.selectedLensFacing, equals('unknown'));
          expect(report.selectedWidth, equals(0));
          expect(report.selectedHeight, equals(0));
          expect(report.imageFormatName, equals('PRIVATE'));
          expect(report.targetFrameCount, equals(0));
          expect(report.renderedFrames, equals(0));
          expect(report.hardwareBufferFrameCount, equals(0));
          expect(report.hardwareBufferClosedCount, equals(0));
          expect(report.imageClosedCount, equals(0));
          expect(report.syncFenceAwaitedCount, equals(0));
          expect(report.syncFenceClosedCount, equals(0));
          expect(report.firstFrameTimestampNs, isNull);
          expect(report.lastFrameTimestampNs, isNull);
          expect(report.monotonicFrameTimestamps, isTrue);
          expect(report.nativeRenderRawFrames, isEmpty);
          expect(report.finalNativeRenderRaw, isNull);
          expect(report.nativeSessionCreated, isFalse);
          expect(report.nativeGenerationId, equals(0));
          expect(report.nativeSessionDestroyed, isFalse);
          expect(report.sessionClosed, isFalse);
          expect(report.deviceClosed, isFalse);
          expect(report.imageReaderClosed, isFalse);
          expect(report.surfaceProducerReleased, isFalse);
          expect(
            report.decision,
            equals(VGCamera2TextureNativeRenderLoopSmokeDecision.captureFailed),
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
        final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
          for (final key in _createSampleRawMap().keys) key: null,
        });
        expect(
          report,
          equals(
            const VGCamera2TextureNativeRenderLoopSmokeReport(
              success: false,
              started: false,
              textureId: -1,
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
              selectedSensorOrientationDegrees: -1,
              renderedRotationDegrees: 0,
              renderedMirrorHorizontal: false,
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
              nativeSessionCreated: false,
              nativeGenerationId: 0,
              nativeSessionDestroyed: false,
              sessionClosed: false,
              deviceClosed: false,
              imageReaderClosed: false,
              surfaceProducerReleased: false,
              decision:
                  VGCamera2TextureNativeRenderLoopSmokeDecision.captureFailed,
              reasons: [],
              events: [],
              diagnostics: {},
              durationMs: 0,
            ),
          ),
        );

        final parsed = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
          'success': true,
          'started': true,
          'textureId': 42.0,
          'apiLevel': 34.0,
          'selectedWidth': 640.0,
          'selectedHeight': 480.0,
          'selectedSensorOrientationDegrees': 90.0,
          'renderedRotationDegrees': 90.0,
          'renderedMirrorHorizontal': true,
          'targetFrameCount': 5.0,
          'renderedFrames': 5.0,
          'hardwareBufferFrameCount': 5.0,
          'hardwareBufferClosedCount': 5.0,
          'imageClosedCount': 5.0,
          'syncFenceAwaitedCount': 5.0,
          'syncFenceClosedCount': 5.0,
          'firstFrameTimestampNs': 1000000000.0,
          'lastFrameTimestampNs': 1000133333.0,
          'nativeGenerationId': 100.0,
          'durationMs': 250.0,
          'nativeRenderRawFrames': <Object?>[
            'status=PASS;frameIndex=0',
            123,
            null,
          ],
          'reasons': <Object?>['r1', 123, null],
          'events': <Object?>['e1', 456],
          'diagnostics': <Object?, Object?>{'nested': 'ok'},
        });
        expect(parsed.textureId, equals(42));
        expect(parsed.apiLevel, equals(34));
        expect(parsed.selectedWidth, equals(640));
        expect(parsed.selectedHeight, equals(480));
        expect(parsed.selectedSensorOrientationDegrees, equals(90));
        expect(parsed.renderedRotationDegrees, equals(90));
        expect(parsed.renderedMirrorHorizontal, isTrue);
        expect(parsed.targetFrameCount, equals(5));
        expect(parsed.renderedFrames, equals(5));
        expect(parsed.hardwareBufferFrameCount, equals(5));
        expect(parsed.hardwareBufferClosedCount, equals(5));
        expect(parsed.imageClosedCount, equals(5));
        expect(parsed.syncFenceAwaitedCount, equals(5));
        expect(parsed.syncFenceClosedCount, equals(5));
        expect(parsed.firstFrameTimestampNs, equals(1000000000));
        expect(parsed.lastFrameTimestampNs, equals(1000133333));
        expect(parsed.nativeGenerationId, equals(100));
        expect(parsed.durationMs, equals(250));
        expect(
          parsed.nativeRenderRawFrames,
          equals(['status=PASS;frameIndex=0', '123']),
        );
        expect(parsed.reasons, equals(['r1', '123']));
        expect(parsed.events, equals(['e1', '456']));
        expect(parsed.diagnostics, equals({'nested': 'ok'}));

        final parsedBad = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
          <Object?, Object?>{
            'nativeRenderRawFrames': 'not_a_list',
            'reasons': 'not_a_list',
            'events': 12345,
            'diagnostics': 'not_a_map',
          },
        );
        expect(parsedBad.nativeRenderRawFrames, isEmpty);
        expect(parsedBad.reasons, isEmpty);
        expect(parsedBad.events, isEmpty);
        expect(parsedBad.diagnostics, isEmpty);
      },
    );
  });

  group('VGCamera2TextureNativeRenderLoopSmokeReport getters', () {
    test('isPermissionRequired reflects decision strictly', () {
      expect(
        _createSampleReport({
          'decision': 'permissionRequired',
        }).isPermissionRequired,
        isTrue,
      );
      expect(
        _createSampleReport({
          'decision': 'textureNativeRenderLoopPassed',
        }).isPermissionRequired,
        isFalse,
      );
    });

    test('isTextureNativeRenderLoopPassed reflects decision strictly', () {
      expect(
        _createSampleReport({
          'decision': 'textureNativeRenderLoopPassed',
        }).isTextureNativeRenderLoopPassed,
        isTrue,
      );
      expect(
        _createSampleReport({
          'decision': 'nativeRenderFailed',
        }).isTextureNativeRenderLoopPassed,
        isFalse,
      );
    });

    test('isDisposed reflects decision strictly', () {
      expect(_createSampleReport({'decision': 'disposed'}).isDisposed, isTrue);
      expect(
        _createSampleReport({
          'decision': 'textureNativeRenderLoopPassed',
        }).isDisposed,
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
      'isCleanedUp requires sessionClosed && deviceClosed && imageReaderClosed && nativeSessionDestroyed',
      () {
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
          }).isCleanedUp,
          isTrue,
        );
        expect(
          _createSampleReport({
            'sessionClosed': false,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': false,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': false,
            'nativeSessionDestroyed': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': false,
          }).isCleanedUp,
          isFalse,
        );
      },
    );

    test(
      'hasValidSensorOrientation accepts 0, 90, 180, 270 and rejects others',
      () {
        for (final valid in const [0, 90, 180, 270]) {
          expect(
            _createSampleReport({
              'selectedSensorOrientationDegrees': valid,
            }).hasValidSensorOrientation,
            isTrue,
          );
        }
        for (final invalid in const [-1, 45, 100, 360]) {
          expect(
            _createSampleReport({
              'selectedSensorOrientationDegrees': invalid,
            }).hasValidSensorOrientation,
            isFalse,
          );
        }
      },
    );
    test(
      'hasExpectedRenderMirror evaluates true for matching lensFacing and mirror settings',
      () {
        expect(
          _createSampleReport({
            'selectedLensFacing': 'front',
            'renderedMirrorHorizontal': true,
          }).hasExpectedRenderMirror,
          isTrue,
        );
        expect(
          _createSampleReport({
            'selectedLensFacing': 'back',
            'renderedMirrorHorizontal': false,
          }).hasExpectedRenderMirror,
          isTrue,
        );
        expect(
          _createSampleReport({
            'selectedLensFacing': 'external',
            'renderedMirrorHorizontal': false,
          }).hasExpectedRenderMirror,
          isTrue,
        );
        expect(
          _createSampleReport({
            'selectedLensFacing': 'front',
            'renderedMirrorHorizontal': false,
          }).hasExpectedRenderMirror,
          isFalse,
        );
        expect(
          _createSampleReport({
            'selectedLensFacing': 'back',
            'renderedMirrorHorizontal': true,
          }).hasExpectedRenderMirror,
          isFalse,
        );
      },
    );
  });

  group('VGCamera2TextureNativeRenderLoopSmokeReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      for (final snippet in [
        'VGCamera2TextureNativeRenderLoopSmokeReport(',
        'decision: VGCamera2TextureNativeRenderLoopSmokeDecision.textureNativeRenderLoopPassed',
        'success: true',
        'started: true',
        'textureId: 42',
        'apiLevel: 34',
        'cameraId: 0',
        'selectedWidth: 640',
        'selectedHeight: 480',
        'selectedSensorOrientationDegrees: 90',
        'renderedRotationDegrees: 90',
        'renderedMirrorHorizontal: false',
        'targetFrameCount: 5',
        'renderedFrames: 5',
        'hardwareBufferFrameCount: 5',
        'hardwareBufferClosedCount: 5',
        'imageClosedCount: 5',
        'syncFenceAwaitedCount: 5',
        'syncFenceClosedCount: 5',
        'nativeSessionCreated: true',
        'nativeGenerationId: 100',
        'nativeSessionDestroyed: true',
        'sessionClosed: true',
        'deviceClosed: true',
        'imageReaderClosed: true',
        'surfaceProducerReleased: false',
        'firstFrameTimestampNs: 1000000000',
        'lastFrameTimestampNs: 1000133333',
        'monotonicFrameTimestamps: true',
        'finalNativeRenderRaw: status=PASS;frameIndex=4;renderedFrames=5;generationId=100;renderResult=success;releaseResult=success',
        'durationMs: 350',
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
        {'started': false},
        {'textureId': 99},
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
        {'selectedSensorOrientationDegrees': 270},
        {'renderedRotationDegrees': 180},
        {'renderedMirrorHorizontal': true},
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
            'status=PASS;frameIndex=0;renderedFrames=1;generationId=100;',
          ],
        },
        {'finalNativeRenderRaw': 'status=FAIL;'},
        {'nativeSessionCreated': false},
        {'nativeGenerationId': 200},
        {'nativeSessionDestroyed': false},
        {'sessionClosed': false},
        {'deviceClosed': false},
        {'imageReaderClosed': false},
        {'surfaceProducerReleased': true},
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
    'VGCamera2TextureNativeRenderLoopSmokeReport start/dispose MethodChannel contracts',
    () {
      Future<MethodCall> captureCall({
        required Future<Object?> Function(MethodChannel channel) action,
        Object? response,
      }) async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_vanguard_texture_native_render_loop_contract',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return response;
        });
        await action(channel);
        return capturedCall!;
      }

      test(
        'start invokes startAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke with default args and omits null cameraId',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  channel: channel,
                ),
            response: {'textureId': 42, 'targetFrameCount': 5},
          );

          expect(
            call.method,
            equals(
              'startAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke',
            ),
          );
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments.containsKey('cameraId'), isFalse);
          expect(arguments['applySensorOrientationTransform'], isTrue);
          expect(arguments['timeoutMs'], equals(10000));
          expect(arguments['maxWidth'], equals(640));
          expect(arguments['maxHeight'], equals(480));
          expect(arguments['frameCount'], equals(5));
        },
      );

      test(
        'start passes explicit nonblank cameraId, custom timeout, custom dimensions, and custom frameCount',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  cameraId: '1',
                  timeout: const Duration(seconds: 12),
                  maxWidth: 1280,
                  maxHeight: 720,
                  frameCount: 10,
                  channel: channel,
                ),
            response: {'textureId': 42, 'targetFrameCount': 10},
          );

          expect(
            call.method,
            equals(
              'startAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke',
            ),
          );
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['cameraId'], equals('1'));
          expect(arguments['applySensorOrientationTransform'], isTrue);
          expect(arguments['timeoutMs'], equals(12000));
          expect(arguments['maxWidth'], equals(1280));
          expect(arguments['maxHeight'], equals(720));
          expect(arguments['frameCount'], equals(10));
        },
      );

      test('start omits blank or whitespace-only cameraId', () async {
        final call = await captureCall(
          action: (channel) =>
              VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                cameraId: '   ',
                channel: channel,
              ),
          response: {'textureId': 42, 'targetFrameCount': 5},
        );

        final arguments = call.arguments as Map<Object?, Object?>;
        expect(arguments.containsKey('cameraId'), isFalse);
        expect(arguments['applySensorOrientationTransform'], isTrue);
        expect(arguments['timeoutMs'], equals(10000));
        expect(arguments['maxWidth'], equals(640));
        expect(arguments['maxHeight'], equals(480));
        expect(arguments['frameCount'], equals(5));
      });

      test('start trims and lowercases lensFacing to front', () async {
        final call = await captureCall(
          action: (channel) =>
              VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                lensFacing: ' Front ',
                channel: channel,
              ),
          response: {'textureId': 42, 'targetFrameCount': 5},
        );

        expect(
          call.method,
          equals(
            'startAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke',
          ),
        );
        final arguments = call.arguments as Map<Object?, Object?>;
        expect(arguments['lensFacing'], equals('front'));
        expect(arguments.containsKey('cameraId'), isFalse);
        expect(arguments['applySensorOrientationTransform'], isTrue);
      });

      test('start omits blank or whitespace-only lensFacing', () async {
        final call = await captureCall(
          action: (channel) =>
              VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                lensFacing: '   ',
                channel: channel,
              ),
          response: {'textureId': 42, 'targetFrameCount': 5},
        );

        final arguments = call.arguments as Map<Object?, Object?>;
        expect(arguments.containsKey('lensFacing'), isFalse);
        expect(arguments['applySensorOrientationTransform'], isTrue);
      });

      test(
        'start passes both nonblank cameraId and lensFacing so native can apply cameraId precedence',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  cameraId: ' 1 ',
                  lensFacing: ' Front ',
                  channel: channel,
                ),
            response: {'textureId': 42, 'targetFrameCount': 5},
          );

          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['cameraId'], equals('1'));
          expect(arguments['lensFacing'], equals('front'));
          expect(arguments['applySensorOrientationTransform'], isTrue);
        },
      );

      test(
        'start uses default vanguard_media_engine channel when omitted',
        () async {
          MethodCall? capturedCall;
          binaryMessenger.setMockMethodCallHandler(defaultChannel, (
            call,
          ) async {
            capturedCall = call;
            return {'textureId': 101, 'targetFrameCount': 5};
          });

          final result =
              await VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke();

          expect(capturedCall, isNotNull);
          expect(
            capturedCall!.method,
            equals(
              'startAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke',
            ),
          );
          expect(result.textureId, equals(101));
          expect(result.targetFrameCount, equals(5));
        },
      );

      test('start handles non-map response defensively', () async {
        const channel = MethodChannel('test_start_defensive_channel');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          return 'not_a_map';
        });

        final result =
            await VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
              channel: channel,
            );

        expect(result.textureId, equals(-1));
        expect(result.targetFrameCount, equals(0));
      });

      test(
        'dispose invokes disposeAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke with textureId',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.disposeAndroidCamera2TextureNativeRenderLoopSmoke(
                  textureId: 42,
                  channel: channel,
                ),
            response: {
              'pass': true,
              'textureId': 42,
              'surfaceProducerReleased': true,
              'raw': 'status=OK;disposed=true;textureId=42',
            },
          );

          expect(
            call.method,
            equals(
              'disposeAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke',
            ),
          );
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['textureId'], equals(42));
        },
      );

      test('dispose returns surfaceProducerReleased boolean correctly', () async {
        const channel = MethodChannel('test_dispose_channel');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map<Object?, Object?>;
          if (args['textureId'] == 42) {
            return {'surfaceProducerReleased': true};
          } else {
            return {'surfaceProducerReleased': false};
          }
        });

        final released =
            await VGCamera2TextureNativeRenderLoopSmokeReport.disposeAndroidCamera2TextureNativeRenderLoopSmoke(
              textureId: 42,
              channel: channel,
            );
        expect(released, isTrue);

        final notReleased =
            await VGCamera2TextureNativeRenderLoopSmokeReport.disposeAndroidCamera2TextureNativeRenderLoopSmoke(
              textureId: 99,
              channel: channel,
            );
        expect(notReleased, isFalse);
      });

      test(
        'dispose uses default vanguard_media_engine channel when omitted',
        () async {
          MethodCall? capturedCall;
          binaryMessenger.setMockMethodCallHandler(defaultChannel, (
            call,
          ) async {
            capturedCall = call;
            return {'surfaceProducerReleased': true};
          });

          final result =
              await VGCamera2TextureNativeRenderLoopSmokeReport.disposeAndroidCamera2TextureNativeRenderLoopSmoke(
                textureId: 55,
              );

          expect(capturedCall, isNotNull);
          expect(
            capturedCall!.method,
            equals(
              'disposeAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke',
            ),
          );
          expect(result, isTrue);
        },
      );

      test('dispose handles non-map response defensively', () async {
        const channel = MethodChannel('test_dispose_defensive_channel');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          return null;
        });

        final result =
            await VGCamera2TextureNativeRenderLoopSmokeReport.disposeAndroidCamera2TextureNativeRenderLoopSmoke(
              textureId: 42,
              channel: channel,
            );

        expect(result, isFalse);
      });
    },
  );
}
