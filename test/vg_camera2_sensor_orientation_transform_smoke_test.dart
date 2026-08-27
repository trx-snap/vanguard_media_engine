// vg_camera2_sensor_orientation_transform_smoke_test.dart
// vanguard_media_engine — Phase 3-Unit P: Android Camera2 Sensor Orientation
// Hardware Render Transform in Vulkan Flutter Texture Native Render Loop Smoke Unit Tests.

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
    'VGCamera2SensorOrientationTransformSmoke - Start wrapper parameter forwarding',
    () {
      Future<MethodCall> captureCall({
        required Future<Object?> Function(MethodChannel channel) action,
        Object? response,
      }) async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_vanguard_sensor_orientation_transform_contract',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return response;
        });
        await action(channel);
        return capturedCall!;
      }

      test(
        'startAndroidCamera2TextureNativeRenderLoopSmoke forwards applySensorOrientationTransform=true by default',
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
          expect(arguments['applySensorOrientationTransform'], isTrue);
          expect(arguments['lensFacing'], equals('front'));
          expect(arguments.containsKey('cameraId'), isFalse);
          expect(arguments['timeoutMs'], equals(10000));
          expect(arguments['maxWidth'], equals(640));
          expect(arguments['maxHeight'], equals(480));
          expect(arguments['frameCount'], equals(5));
        },
      );

      test(
        'startAndroidCamera2TextureNativeRenderLoopSmoke forwards explicit applySensorOrientationTransform=false',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  lensFacing: 'front',
                  applySensorOrientationTransform: false,
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
          expect(arguments['applySensorOrientationTransform'], isFalse);
          expect(arguments['lensFacing'], equals('front'));
          expect(arguments.containsKey('cameraId'), isFalse);
        },
      );

      test(
        'startAndroidCamera2TextureNativeRenderLoopSmoke forwards explicit applySensorOrientationTransform=true along with cameraId and lensFacing',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  cameraId: 'front_camera_1',
                  lensFacing: 'front',
                  applySensorOrientationTransform: true,
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
          expect(arguments['cameraId'], equals('front_camera_1'));
          expect(arguments['lensFacing'], equals('front'));
          expect(arguments['applySensorOrientationTransform'], isTrue);
        },
      );
    },
  );

  group(
    'VGCamera2SensorOrientationTransformSmoke - Report parsing & rotation evaluation',
    () {
      test(
        'parses success report with selectedSensorOrientationDegrees=270 and renderedRotationDegrees=270 (hasExpectedRenderRotation=true)',
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
            'diagnostics': const {'transformApplied': true},
            'durationMs': 410,
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
          expect(
            report.decision,
            equals(
              VGCamera2TextureNativeRenderLoopSmokeDecision
                  .textureNativeRenderLoopPassed,
            ),
          );
          expect(report.isTextureNativeRenderLoopPassed, isTrue);
          expect(report.isCleanedUp, isTrue);

          final serialized = report.toMap();
          expect(serialized['success'], isTrue);
          expect(serialized['selectedSensorOrientationDegrees'], equals(270));
          expect(serialized['renderedRotationDegrees'], equals(270));

          final roundTrip = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            serialized,
          );
          expect(roundTrip, equals(report));
          expect(roundTrip.hasExpectedRenderRotation, isTrue);
        },
      );

      test(
        'parses transform-disabled report with renderedRotationDegrees=0 and selectedSensorOrientationDegrees=270 causing hasExpectedRenderRotation=false',
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
            'decision': 'textureNativeRenderLoopPassed',
            'reasons': const <String>[],
            'events': const [
              'openCameraRequested',
              'onOpened',
              'createCaptureSessionRequested',
              'onConfigured',
              'repeatingRequestStarted',
              'nativeRenderAttempted:frameIndex=0',
              'nativeRenderPassed:renderedFrames=5',
              'onSessionClosed',
              'onDeviceClosed',
            ],
            'diagnostics': const {'transformApplied': false},
            'durationMs': 400,
          };

          final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            raw,
          );

          expect(report.success, isTrue);
          expect(report.selectedSensorOrientationDegrees, equals(270));
          expect(report.renderedRotationDegrees, equals(0));
          expect(report.hasValidSensorOrientation, isTrue);
          expect(report.hasExpectedRenderRotation, isFalse);
          expect(
            report.decision,
            equals(
              VGCamera2TextureNativeRenderLoopSmokeDecision
                  .textureNativeRenderLoopPassed,
            ),
          );

          final serialized = report.toMap();
          expect(serialized['selectedSensorOrientationDegrees'], equals(270));
          expect(serialized['renderedRotationDegrees'], equals(0));

          final roundTrip = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            serialized,
          );
          expect(roundTrip, equals(report));
          expect(roundTrip.hasExpectedRenderRotation, isFalse);
        },
      );

      test('invalidSensorOrientation parse keeps renderedRotationDegrees=0', () {
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
            'onSessionClosed',
            'onDeviceClosed',
          ],
          'diagnostics': const <String, Object?>{},
          'durationMs': 450,
        };

        final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(raw);

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
        expect(report.hasValidSensorOrientation, isFalse);
        expect(report.hasExpectedRenderRotation, isFalse);
        expect(report.reasons, equals(const ['invalid_sensor_orientation']));
      });

      test(
        'missing sensor orientation (-1) keeps renderedRotationDegrees=0 and evaluates hasExpectedRenderRotation=false',
        () {
          final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
            'selectedLensFacing': 'front',
            'selectedSensorOrientationDegrees': -1,
            'renderedRotationDegrees': 0,
            'decision': 'invalidSensorOrientation',
            'reasons': ['invalid_sensor_orientation'],
            'success': false,
          });

          expect(report.selectedSensorOrientationDegrees, equals(-1));
          expect(report.renderedRotationDegrees, equals(0));
          expect(report.hasValidSensorOrientation, isFalse);
          expect(report.hasExpectedRenderRotation, isFalse);
        },
      );

      test(
        'verifies hasExpectedRenderRotation getter across all standard orientations (0, 90, 180, 270) when matching vs mismatching',
        () {
          for (final orientation in const [0, 90, 180, 270]) {
            // Matching
            final matchingReport =
                VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
                  'selectedSensorOrientationDegrees': orientation,
                  'renderedRotationDegrees': orientation,
                  'decision': 'textureNativeRenderLoopPassed',
                  'success': true,
                });
            expect(matchingReport.hasValidSensorOrientation, isTrue);
            expect(matchingReport.hasExpectedRenderRotation, isTrue);

            // Mismatching (rendered as 0 when sensor is non-zero)
            if (orientation != 0) {
              final mismatchReport =
                  VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
                    'selectedSensorOrientationDegrees': orientation,
                    'renderedRotationDegrees': 0,
                    'decision': 'textureNativeRenderLoopPassed',
                    'success': true,
                  });
              expect(mismatchReport.hasValidSensorOrientation, isTrue);
              expect(mismatchReport.hasExpectedRenderRotation, isFalse);
            }
          }
        },
      );
    },
  );
}
