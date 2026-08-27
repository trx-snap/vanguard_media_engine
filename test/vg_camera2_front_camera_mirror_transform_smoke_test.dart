// vg_camera2_front_camera_mirror_transform_smoke_test.dart
// vanguard_media_engine — Phase 3-Unit Q: Android Camera2 Front-Facing
// Horizontal Mirror Render Transform in Vulkan Flutter Texture Native Render Loop Smoke Unit Tests.

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
    'VGCamera2FrontCameraMirrorTransformSmoke - Start wrapper parameter forwarding',
    () {
      Future<MethodCall> captureCall({
        required Future<Object?> Function(MethodChannel channel) action,
        Object? response,
      }) async {
        MethodCall? capturedCall;
        const channel = MethodChannel(
          'test_vanguard_front_camera_mirror_contract',
        );
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return response;
        });
        await action(channel);
        return capturedCall!;
      }

      test(
        'startAndroidCamera2TextureNativeRenderLoopSmoke forwards lensFacing: front, default orientation transform true, and explicit mirrorHorizontal: true',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  lensFacing: 'front',
                  mirrorHorizontal: true,
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
          expect(arguments['applySensorOrientationTransform'], isTrue);
          expect(arguments['mirrorHorizontal'], isTrue);
          expect(arguments.containsKey('cameraId'), isFalse);
          expect(arguments['timeoutMs'], equals(10000));
          expect(arguments['maxWidth'], equals(640));
          expect(arguments['maxHeight'], equals(480));
          expect(arguments['frameCount'], equals(5));
        },
      );

      test(
        'startAndroidCamera2TextureNativeRenderLoopSmoke forwards explicit mirrorHorizontal: false along with lensFacing: back',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  lensFacing: 'back',
                  mirrorHorizontal: false,
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
          expect(arguments['lensFacing'], equals('back'));
          expect(arguments['applySensorOrientationTransform'], isTrue);
          expect(arguments['mirrorHorizontal'], isFalse);
        },
      );

      test(
        'startAndroidCamera2TextureNativeRenderLoopSmoke omits mirrorHorizontal when omitted or null',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  lensFacing: 'front',
                  channel: channel,
                ),
            response: {'textureId': 10, 'targetFrameCount': 5},
          );

          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['lensFacing'], equals('front'));
          expect(arguments.containsKey('mirrorHorizontal'), isFalse);
        },
      );

      test(
        'startAndroidCamera2TextureNativeRenderLoopSmoke forwards all arguments including cameraId, lensFacing, orientation, mirror, dimensions, and frameCount',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  cameraId: 'front_camera_0',
                  lensFacing: 'front',
                  applySensorOrientationTransform: true,
                  mirrorHorizontal: true,
                  timeout: const Duration(seconds: 12),
                  maxWidth: 1280,
                  maxHeight: 720,
                  frameCount: 10,
                  channel: channel,
                ),
            response: {'textureId': 10, 'targetFrameCount': 10},
          );

          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['cameraId'], equals('front_camera_0'));
          expect(arguments['lensFacing'], equals('front'));
          expect(arguments['applySensorOrientationTransform'], isTrue);
          expect(arguments['mirrorHorizontal'], isTrue);
          expect(arguments['timeoutMs'], equals(12000));
          expect(arguments['maxWidth'], equals(1280));
          expect(arguments['maxHeight'], equals(720));
          expect(arguments['frameCount'], equals(10));
        },
      );
    },
  );

  group(
    'VGCamera2FrontCameraMirrorTransformSmoke - Report parsing & mirror evaluation',
    () {
      test(
        'parses front camera success report with sensorOrientation=270, renderedRotationDegrees=270, renderedMirrorHorizontal=true, native raw containing mirrorHorizontal=true, hasExpectedRenderMirror=true',
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
            'renderedMirrorHorizontal': true,
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
              'status=PASS;frameIndex=0;renderedFrames=1;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=270;mirrorHorizontal=true',
              'status=PASS;frameIndex=1;renderedFrames=2;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=270;mirrorHorizontal=true',
              'status=PASS;frameIndex=2;renderedFrames=3;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=270;mirrorHorizontal=true',
              'status=PASS;frameIndex=3;renderedFrames=4;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=270;mirrorHorizontal=true',
              'status=PASS;frameIndex=4;renderedFrames=5;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=270;mirrorHorizontal=true',
            ],
            'finalNativeRenderRaw':
                'status=PASS;frameIndex=4;renderedFrames=5;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=270;mirrorHorizontal=true',
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
            'diagnostics': const {'mirrorApplied': true},
            'durationMs': 430,
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
          expect(report.renderedMirrorHorizontal, isTrue);
          expect(report.hasExpectedRenderRotation, isTrue);
          expect(report.hasExpectedRenderMirror, isTrue);
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
          expect(
            report.nativeRenderRawFrames.every(
              (r) =>
                  r.contains('rotationDegrees=270') &&
                  r.contains('mirrorHorizontal=true'),
            ),
            isTrue,
          );
          expect(
            report.finalNativeRenderRaw,
            contains('rotationDegrees=270;mirrorHorizontal=true'),
          );

          final serialized = report.toMap();
          expect(serialized['success'], isTrue);
          expect(serialized['selectedLensFacing'], equals('front'));
          expect(serialized['selectedSensorOrientationDegrees'], equals(270));
          expect(serialized['renderedRotationDegrees'], equals(270));
          expect(serialized['renderedMirrorHorizontal'], isTrue);

          final roundTrip = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            serialized,
          );
          expect(roundTrip, equals(report));
          expect(roundTrip.hasExpectedRenderRotation, isTrue);
          expect(roundTrip.hasExpectedRenderMirror, isTrue);
          expect(roundTrip.renderedMirrorHorizontal, isTrue);
        },
      );

      test(
        'parses back camera / explicit false report with selectedLensFacing=back and renderedMirrorHorizontal=false having hasExpectedRenderMirror=true',
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
              'status=PASS;frameIndex=0;renderedFrames=1;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=90;mirrorHorizontal=false',
              'status=PASS;frameIndex=1;renderedFrames=2;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=90;mirrorHorizontal=false',
              'status=PASS;frameIndex=2;renderedFrames=3;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=90;mirrorHorizontal=false',
              'status=PASS;frameIndex=3;renderedFrames=4;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=90;mirrorHorizontal=false',
              'status=PASS;frameIndex=4;renderedFrames=5;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=90;mirrorHorizontal=false',
            ],
            'finalNativeRenderRaw':
                'status=PASS;frameIndex=4;renderedFrames=5;generationId=101;renderResult=success;releaseResult=success;rotationDegrees=90;mirrorHorizontal=false',
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
            'diagnostics': const {'mirrorApplied': false},
            'durationMs': 380,
          };

          final report = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            raw,
          );

          expect(report.success, isTrue);
          expect(report.selectedLensFacing, equals('back'));
          expect(report.renderedMirrorHorizontal, isFalse);
          expect(report.hasExpectedRenderMirror, isTrue);

          final serialized = report.toMap();
          expect(serialized['selectedLensFacing'], equals('back'));
          expect(serialized['renderedMirrorHorizontal'], isFalse);

          final roundTrip = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            serialized,
          );
          expect(roundTrip, equals(report));
          expect(roundTrip.hasExpectedRenderMirror, isTrue);
        },
      );

      test(
        'explicit mismatch parses with hasExpectedRenderMirror=false for front unmirrored and back mirrored',
        () {
          // Front camera unmirrored mismatch
          final frontUnmirrored =
              VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
                'success': true,
                'selectedLensFacing': 'front',
                'renderedMirrorHorizontal': false,
                'decision': 'textureNativeRenderLoopPassed',
              });
          expect(frontUnmirrored.selectedLensFacing, equals('front'));
          expect(frontUnmirrored.renderedMirrorHorizontal, isFalse);
          expect(frontUnmirrored.hasExpectedRenderMirror, isFalse);

          // Back camera mirrored mismatch
          final backMirrored =
              VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
                'success': true,
                'selectedLensFacing': 'back',
                'renderedMirrorHorizontal': true,
                'decision': 'textureNativeRenderLoopPassed',
              });
          expect(backMirrored.selectedLensFacing, equals('back'));
          expect(backMirrored.renderedMirrorHorizontal, isTrue);
          expect(backMirrored.hasExpectedRenderMirror, isFalse);

          // External camera mirrored mismatch
          final externalMirrored =
              VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
                'success': true,
                'selectedLensFacing': 'external',
                'renderedMirrorHorizontal': true,
                'decision': 'textureNativeRenderLoopPassed',
              });
          expect(externalMirrored.selectedLensFacing, equals('external'));
          expect(externalMirrored.renderedMirrorHorizontal, isTrue);
          expect(externalMirrored.hasExpectedRenderMirror, isFalse);

          // External camera unmirrored match
          final externalUnmirrored =
              VGCamera2TextureNativeRenderLoopSmokeReport.fromMap({
                'success': true,
                'selectedLensFacing': 'external',
                'renderedMirrorHorizontal': false,
                'decision': 'textureNativeRenderLoopPassed',
              });
          expect(externalUnmirrored.selectedLensFacing, equals('external'));
          expect(externalUnmirrored.renderedMirrorHorizontal, isFalse);
          expect(externalUnmirrored.hasExpectedRenderMirror, isTrue);
        },
      );
    },
  );
}
