// vg_camera2_front_camera_texture_smoke_test.dart
// vanguard_media_engine — Phase 3-Unit O: Android Camera2 Front-Facing Lens Selection &
// Sensor Orientation Normalization Flutter Texture Native Render Loop Smoke Unit Tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group(
    'VGCamera2FrontCameraTextureSmokeReport - Front camera parsing & round-trip',
    () {
      test(
        'parses front camera success report with selectedLensFacing=front, sensorOrientation=270, decision=textureNativeRenderLoopPassed, success=true',
        () {
          final raw = <String, Object?>{
            'success': true,
            'started': true,
            'textureId': 10,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'attemptedOpen': true,
            'opened': true,
            'sessionConfigured': true,
            'repeatingStarted': true,
            'cameraId': '1',
            'selectedLensFacing': 'front',
            'selectedWidth': 640,
            'selectedHeight': 480,
            'selectedSensorOrientationDegrees': 270,
            'renderedRotationDegrees': 270,
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
              'status=PASS;frameIndex=0;renderedFrames=1;generationId=101;renderResult=success;releaseResult=success',
              'status=PASS;frameIndex=1;renderedFrames=2;generationId=101;renderResult=success;releaseResult=success',
              'status=PASS;frameIndex=2;renderedFrames=3;generationId=101;renderResult=success;releaseResult=success',
              'status=PASS;frameIndex=3;renderedFrames=4;generationId=101;renderResult=success;releaseResult=success',
              'status=PASS;frameIndex=4;renderedFrames=5;generationId=101;renderResult=success;releaseResult=success',
            ],
            'finalNativeRenderRaw':
                'status=PASS;frameIndex=4;renderedFrames=5;generationId=101;renderResult=success;releaseResult=success',
            'nativeSessionCreated': true,
            'nativeGenerationId': 101,
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
            'diagnostics': const {'lens': 'front_facing'},
            'durationMs': 420,
          };

          final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            raw,
          );

          expect(report.success, isTrue);
          expect(report.started, isTrue);
          expect(report.textureId, equals(10));
          expect(report.apiLevel, equals(34));
          expect(report.hasCameraPermission, isTrue);
          expect(report.attemptedOpen, isTrue);
          expect(report.opened, isTrue);
          expect(report.sessionConfigured, isTrue);
          expect(report.repeatingStarted, isTrue);
          expect(report.cameraId, equals('1'));
          expect(report.selectedLensFacing, equals('front'));
          expect(report.selectedWidth, equals(640));
          expect(report.selectedHeight, equals(480));
          expect(report.selectedSensorOrientationDegrees, equals(270));
          expect(report.renderedRotationDegrees, equals(270));
          expect(report.hasExpectedRenderRotation, isTrue);
          expect(report.hasValidSensorOrientation, isTrue);
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
              'status=PASS;frameIndex=4;renderedFrames=5;generationId=101;renderResult=success;releaseResult=success',
            ),
          );
          expect(report.nativeSessionCreated, isTrue);
          expect(report.nativeGenerationId, equals(101));
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
          expect(report.diagnostics, equals({'lens': 'front_facing'}));
          expect(report.durationMs, equals(420));

          expect(report.isPermissionRequired, isFalse);
          expect(report.isTextureNativeRenderLoopPassed, isTrue);
          expect(report.isDisposed, isFalse);
          expect(report.isAttempted, isTrue);
          expect(report.completedTargetFrames, isTrue);
          expect(report.isCleanedUp, isTrue);

          final serialized = report.toMap();
          expect(serialized['success'], isTrue);
          expect(serialized['started'], isTrue);
          expect(serialized['textureId'], equals(10));
          expect(serialized['apiLevel'], equals(34));
          expect(serialized['hasCameraPermission'], isTrue);
          expect(serialized['attemptedOpen'], isTrue);
          expect(serialized['opened'], isTrue);
          expect(serialized['sessionConfigured'], isTrue);
          expect(serialized['repeatingStarted'], isTrue);
          expect(serialized['cameraId'], equals('1'));
          expect(serialized['selectedLensFacing'], equals('front'));
          expect(serialized['selectedWidth'], equals(640));
          expect(serialized['selectedHeight'], equals(480));
          expect(serialized['selectedSensorOrientationDegrees'], equals(270));
          expect(serialized['renderedRotationDegrees'], equals(270));
          expect(serialized['imageFormatName'], equals('PRIVATE'));
          expect(serialized['targetFrameCount'], equals(5));
          expect(serialized['renderedFrames'], equals(5));
          expect(
            serialized['decision'],
            equals('textureNativeRenderLoopPassed'),
          );
          expect(serialized['durationMs'], equals(420));

          final roundTrip = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            serialized,
          );
          expect(roundTrip, equals(report));
        },
      );

      test('validates sensor orientations 0, 90, 180, 270 as valid', () {
        for (final orientation in const [0, 90, 180, 270]) {
          final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
            'selectedLensFacing': 'front',
            'selectedSensorOrientationDegrees': orientation,
            'decision': 'textureNativeRenderLoopPassed',
            'success': true,
          });
          expect(report.selectedSensorOrientationDegrees, equals(orientation));
          expect(report.hasValidSensorOrientation, isTrue);
        }
      });
    },
  );

  group(
    'VGCamera2FrontCameraTextureSmokeReport - Invalid sensor orientation decision',
    () {
      test(
        'parses invalidSensorOrientation decision with reason invalid_sensor_orientation and hasValidSensorOrientation=false',
        () {
          final raw = <String, Object?>{
            'success': false,
            'started': true,
            'textureId': 10,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'attemptedOpen': true,
            'opened': true,
            'sessionConfigured': true,
            'repeatingStarted': true,
            'cameraId': '1',
            'selectedLensFacing': 'front',
            'selectedWidth': 640,
            'selectedHeight': 480,
            'selectedSensorOrientationDegrees': 45,
            'renderedRotationDegrees': 0,
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
              'status=PASS;frameIndex=0;renderedFrames=1;generationId=101;renderResult=success;releaseResult=success',
              'status=PASS;frameIndex=1;renderedFrames=2;generationId=101;renderResult=success;releaseResult=success',
              'status=PASS;frameIndex=2;renderedFrames=3;generationId=101;renderResult=success;releaseResult=success',
              'status=PASS;frameIndex=3;renderedFrames=4;generationId=101;renderResult=success;releaseResult=success',
              'status=PASS;frameIndex=4;renderedFrames=5;generationId=101;renderResult=success;releaseResult=success',
            ],
            'finalNativeRenderRaw':
                'status=PASS;frameIndex=4;renderedFrames=5;generationId=101;renderResult=success;releaseResult=success',
            'nativeSessionCreated': true,
            'nativeGenerationId': 101,
            'nativeSessionDestroyed': true,
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'surfaceProducerReleased': false,
            'decision': 'invalidSensorOrientation',
            'reasons': const ['invalid_sensor_orientation'],
            'events': const [
              'openCameraRequested',
              'onOpened',
              'createCaptureSessionRequested',
              'onConfigured',
              'repeatingRequestStarted',
              'nativeRenderAttempted:frameIndex=0',
              'nativeRenderPassed:renderedFrames=1',
              'onSessionClosed',
              'onDeviceClosed',
            ],
            'diagnostics': const <String, Object?>{},
            'durationMs': 450,
          };

          final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            raw,
          );

          expect(report.success, isFalse);
          expect(
            report.decision,
            equals(
              VGCamera2TextureNativeRenderLoopSmokeDecision
                  .invalidSensorOrientation,
            ),
          );
          expect(report.selectedLensFacing, equals('front'));
          expect(report.selectedSensorOrientationDegrees, equals(45));
          expect(report.renderedRotationDegrees, equals(0));
          expect(report.hasExpectedRenderRotation, isFalse);
          expect(report.hasValidSensorOrientation, isFalse);
          expect(report.isTextureNativeRenderLoopPassed, isFalse);
          expect(report.reasons, equals(const ['invalid_sensor_orientation']));

          final serialized = report.toMap();
          expect(serialized['decision'], equals('invalidSensorOrientation'));
          expect(serialized['selectedSensorOrientationDegrees'], equals(45));
          expect(serialized['renderedRotationDegrees'], equals(0));
          expect(
            serialized['reasons'],
            equals(const ['invalid_sensor_orientation']),
          );

          final roundTrip = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            serialized,
          );
          expect(roundTrip, equals(report));
          expect(roundTrip.hasValidSensorOrientation, isFalse);
          expect(roundTrip.hasExpectedRenderRotation, isFalse);
        },
      );

      test(
        'sensor orientation -1 evaluates hasValidSensorOrientation=false',
        () {
          final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
            'selectedLensFacing': 'front',
            'selectedSensorOrientationDegrees': -1,
            'decision': 'invalidSensorOrientation',
            'reasons': ['invalid_sensor_orientation'],
            'success': false,
          });
          expect(report.selectedSensorOrientationDegrees, equals(-1));
          expect(report.hasValidSensorOrientation, isFalse);
          expect(
            report.decision,
            equals(
              VGCamera2TextureNativeRenderLoopSmokeDecision
                  .invalidSensorOrientation,
            ),
          );
        },
      );
    },
  );

  group(
    'VGCamera2FrontCameraTextureSmokeReport - Native guard-shaped failure maps',
    () {
      test(
        'handles requested_lens_facing_not_found as cameraUnavailable with attemptedOpen=false, cameraId=null, and selectedLensFacing as requested',
        () {
          final raw = <String, Object?>{
            'success': false,
            'started': true,
            'textureId': 12,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'attemptedOpen': false,
            'opened': false,
            'sessionConfigured': false,
            'repeatingStarted': false,
            'cameraId': null,
            'selectedLensFacing': 'front',
            'selectedWidth': 0,
            'selectedHeight': 0,
            'selectedSensorOrientationDegrees': -1,
            'imageFormatName': 'PRIVATE',
            'targetFrameCount': 5,
            'renderedFrames': 0,
            'hardwareBufferFrameCount': 0,
            'hardwareBufferClosedCount': 0,
            'imageClosedCount': 0,
            'syncFenceAwaitedCount': 0,
            'syncFenceClosedCount': 0,
            'firstFrameTimestampNs': null,
            'lastFrameTimestampNs': null,
            'monotonicFrameTimestamps': true,
            'nativeRenderRawFrames': const <String>[],
            'finalNativeRenderRaw': null,
            'nativeSessionCreated': false,
            'nativeGenerationId': 0,
            'nativeSessionDestroyed': false,
            'sessionClosed': false,
            'deviceClosed': false,
            'imageReaderClosed': false,
            'surfaceProducerReleased': false,
            'decision': 'cameraUnavailable',
            'reasons': const ['requested_lens_facing_not_found'],
            'events': const <String>[],
            'diagnostics': const <String, Object?>{},
            'durationMs': 12,
          };

          final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            raw,
          );

          expect(report.success, isFalse);
          expect(report.started, isTrue);
          expect(report.attemptedOpen, isFalse);
          expect(report.isAttempted, isFalse);
          expect(report.opened, isFalse);
          expect(report.cameraId, isNull);
          expect(report.selectedLensFacing, equals('front'));
          expect(report.selectedSensorOrientationDegrees, equals(-1));
          expect(report.hasValidSensorOrientation, isFalse);
          expect(
            report.decision,
            equals(
              VGCamera2TextureNativeRenderLoopSmokeDecision.cameraUnavailable,
            ),
          );
          expect(
            report.reasons,
            equals(const ['requested_lens_facing_not_found']),
          );
          expect(report.isTextureNativeRenderLoopPassed, isFalse);
          expect(report.isCleanedUp, isFalse);
        },
      );

      test(
        'handles requested_lens_facing_invalid as cameraUnavailable with attemptedOpen=false, cameraId=null, and selectedLensFacing as requested',
        () {
          final raw = <String, Object?>{
            'success': false,
            'started': true,
            'textureId': 12,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'attemptedOpen': false,
            'opened': false,
            'sessionConfigured': false,
            'repeatingStarted': false,
            'cameraId': null,
            'selectedLensFacing': 'upside_down',
            'selectedWidth': 0,
            'selectedHeight': 0,
            'selectedSensorOrientationDegrees': -1,
            'imageFormatName': 'PRIVATE',
            'targetFrameCount': 5,
            'renderedFrames': 0,
            'hardwareBufferFrameCount': 0,
            'hardwareBufferClosedCount': 0,
            'imageClosedCount': 0,
            'syncFenceAwaitedCount': 0,
            'syncFenceClosedCount': 0,
            'firstFrameTimestampNs': null,
            'lastFrameTimestampNs': null,
            'monotonicFrameTimestamps': true,
            'nativeRenderRawFrames': const <String>[],
            'finalNativeRenderRaw': null,
            'nativeSessionCreated': false,
            'nativeGenerationId': 0,
            'nativeSessionDestroyed': false,
            'sessionClosed': false,
            'deviceClosed': false,
            'imageReaderClosed': false,
            'surfaceProducerReleased': false,
            'decision': 'cameraUnavailable',
            'reasons': const ['requested_lens_facing_invalid'],
            'events': const <String>[],
            'diagnostics': const <String, Object?>{},
            'durationMs': 8,
          };

          final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            raw,
          );

          expect(report.success, isFalse);
          expect(report.started, isTrue);
          expect(report.attemptedOpen, isFalse);
          expect(report.isAttempted, isFalse);
          expect(report.opened, isFalse);
          expect(report.cameraId, isNull);
          expect(report.selectedLensFacing, equals('upside_down'));
          expect(report.selectedSensorOrientationDegrees, equals(-1));
          expect(report.hasValidSensorOrientation, isFalse);
          expect(
            report.decision,
            equals(
              VGCamera2TextureNativeRenderLoopSmokeDecision.cameraUnavailable,
            ),
          );
          expect(
            report.reasons,
            equals(const ['requested_lens_facing_invalid']),
          );
          expect(report.isTextureNativeRenderLoopPassed, isFalse);
        },
      );
    },
  );

  group(
    'VGCamera2FrontCameraTextureSmokeReport - Start wrapper parameter forwarding',
    () {
      Future<MethodCall> captureCall({
        required Future<Object?> Function(MethodChannel channel) action,
        Object? response,
      }) async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_vanguard_front_camera_smoke_contract',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return response;
        });
        await action(channel);
        return capturedCall!;
      }

      test(
        'startAndroidCamera2TextureNativeRenderLoopSmoke forwards front lensFacing correctly',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  lensFacing: 'front',
                  channel: channel,
                ),
            response: {'textureId': 10, 'targetFrameCount': 5},
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
          expect(arguments['timeoutMs'], equals(10000));
          expect(arguments['maxWidth'], equals(640));
          expect(arguments['maxHeight'], equals(480));
          expect(arguments['frameCount'], equals(5));
        },
      );

      test(
        'startAndroidCamera2TextureNativeRenderLoopSmoke forwards both nonblank cameraId and lensFacing',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  cameraId: 'front_camera_0',
                  lensFacing: 'front',
                  channel: channel,
                ),
            response: {'textureId': 10, 'targetFrameCount': 5},
          );

          expect(
            call.method,
            equals(
              'startAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke',
            ),
          );
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['cameraId'], equals('front_camera_0'));
          expect(arguments['lensFacing'], equals('front'));
          expect(arguments['applySensorOrientationTransform'], isTrue);
        },
      );
    },
  );
}
