// vg_camera2_texture_native_render_loop_dispose_smoke_test.dart
// vanguard_media_engine — Phase 3-Unit N: Android Camera2 Flutter Texture
// Native Render Loop Active Dispose/Cancellation Smoke Unit Tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Map<String, Object?> _createSampleDisposedRawMap([
  Map<String, Object?>? overrides,
]) => {
  'success': false,
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
  'imageFormatName': 'PRIVATE',
  'targetFrameCount': 30,
  'renderedFrames': 8,
  'hardwareBufferFrameCount': 8,
  'hardwareBufferClosedCount': 8,
  'imageClosedCount': 8,
  'syncFenceAwaitedCount': 8,
  'syncFenceClosedCount': 8,
  'firstFrameTimestampNs': 1000000000,
  'lastFrameTimestampNs': 1000266666,
  'monotonicFrameTimestamps': true,
  'nativeRenderRawFrames': const [
    'status=PASS;frameIndex=0;renderedFrames=1;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=1;renderedFrames=2;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=2;renderedFrames=3;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=3;renderedFrames=4;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=4;renderedFrames=5;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=5;renderedFrames=6;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=6;renderedFrames=7;generationId=100;renderResult=success;releaseResult=success',
    'status=PASS;frameIndex=7;renderedFrames=8;generationId=100;renderResult=success;releaseResult=success',
  ],
  'finalNativeRenderRaw':
      'status=PASS;frameIndex=7;renderedFrames=8;generationId=100;renderResult=success;releaseResult=success',
  'nativeSessionCreated': true,
  'nativeGenerationId': 100,
  'nativeSessionDestroyed': true,
  'sessionClosed': true,
  'deviceClosed': true,
  'imageReaderClosed': true,
  'surfaceProducerReleased': true,
  'decision': 'disposed',
  'reasons': const ['disposed_during_run'],
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
  'diagnostics': const {'disposeTiming': 'active_run'},
  'durationMs': 180,
  if (overrides != null) ...overrides,
};

VGCamera2TextureNativeRenderLoopSmokeReport _createDisposedReport([
  Map<String, Object?>? overrides,
]) => VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
  _createSampleDisposedRawMap(overrides),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group(
    'VGCamera2TextureNativeRenderLoopSmokeReport disposed report parsing & round-trip',
    () {
      test('disposed completion report parses all fields accurately', () {
        final report = _createDisposedReport();

        expect(report.success, isFalse);
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
        expect(report.imageFormatName, equals('PRIVATE'));
        expect(report.targetFrameCount, equals(30));
        expect(report.renderedFrames, equals(8));
        expect(report.hardwareBufferFrameCount, equals(8));
        expect(report.hardwareBufferClosedCount, equals(8));
        expect(report.imageClosedCount, equals(8));
        expect(report.syncFenceAwaitedCount, equals(8));
        expect(report.syncFenceClosedCount, equals(8));
        expect(report.firstFrameTimestampNs, equals(1000000000));
        expect(report.lastFrameTimestampNs, equals(1000266666));
        expect(report.monotonicFrameTimestamps, isTrue);
        expect(report.nativeRenderRawFrames.length, equals(8));
        expect(
          report.finalNativeRenderRaw,
          equals(
            'status=PASS;frameIndex=7;renderedFrames=8;generationId=100;renderResult=success;releaseResult=success',
          ),
        );
        expect(report.nativeSessionCreated, isTrue);
        expect(report.nativeGenerationId, equals(100));
        expect(report.nativeSessionDestroyed, isTrue);
        expect(report.sessionClosed, isTrue);
        expect(report.deviceClosed, isTrue);
        expect(report.imageReaderClosed, isTrue);
        expect(report.surfaceProducerReleased, isTrue);
        expect(
          report.decision,
          equals(VGCamera2TextureNativeRenderLoopSmokeDecision.disposed),
        );
        expect(report.reasons, equals(const ['disposed_during_run']));
        expect(report.diagnostics, equals({'disposeTiming': 'active_run'}));
        expect(report.durationMs, equals(180));

        expect(report.isDisposed, isTrue);
        expect(report.isAttempted, isTrue);
        expect(report.completedTargetFrames, isFalse);
        expect(report.isCleanedUp, isTrue);
        expect(report.isTextureNativeRenderLoopPassed, isFalse);
        expect(report.isPermissionRequired, isFalse);
      });

      test(
        'disposed completion report round-trips toMap and fromMap cleanly',
        () {
          final report = _createDisposedReport();
          final serialized = report.toMap();

          expect(serialized['success'], isFalse);
          expect(serialized['started'], isTrue);
          expect(serialized['textureId'], equals(42));
          expect(serialized['targetFrameCount'], equals(30));
          expect(serialized['renderedFrames'], equals(8));
          expect(serialized['surfaceProducerReleased'], isTrue);
          expect(serialized['decision'], equals('disposed'));
          expect(serialized['reasons'], equals(['disposed_during_run']));
          expect(serialized['sessionClosed'], isTrue);
          expect(serialized['deviceClosed'], isTrue);
          expect(serialized['imageReaderClosed'], isTrue);
          expect(serialized['nativeSessionDestroyed'], isTrue);

          final deserialized =
              VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(serialized);
          expect(deserialized, equals(report));
          expect(deserialized.hashCode, equals(report.hashCode));
        },
      );

      test(
        'early disposed report before camera open parses and round-trips',
        () {
          final report = _createDisposedReport({
            'attemptedOpen': false,
            'opened': false,
            'sessionConfigured': false,
            'repeatingStarted': false,
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
            'nativeSessionCreated': false,
            'nativeGenerationId': 0,
            'nativeSessionDestroyed': false,
            'sessionClosed': false,
            'deviceClosed': false,
            'imageReaderClosed': false,
            'surfaceProducerReleased': true,
          });

          expect(report.isDisposed, isTrue);
          expect(report.isAttempted, isFalse);
          expect(report.completedTargetFrames, isFalse);
          expect(report.isCleanedUp, isFalse);
          expect(report.renderedFrames, equals(0));

          final roundTrip = VGCamera2TextureNativeRenderLoopSmokeReport.fromMap(
            report.toMap(),
          );
          expect(roundTrip, equals(report));
        },
      );
    },
  );

  group('VGCamera2TextureNativeRenderLoopSmokeReport lifecycle getters', () {
    test('isDisposed accurately identifies disposed decision vs others', () {
      expect(_createDisposedReport().isDisposed, isTrue);
      expect(
        _createDisposedReport({
          'decision': 'textureNativeRenderLoopPassed',
        }).isDisposed,
        isFalse,
      );
      expect(
        _createDisposedReport({'decision': 'openTimeout'}).isDisposed,
        isFalse,
      );
    });

    test('isAttempted reflects attemptedOpen boolean', () {
      expect(
        _createDisposedReport({'attemptedOpen': true}).isAttempted,
        isTrue,
      );
      expect(
        _createDisposedReport({'attemptedOpen': false}).isAttempted,
        isFalse,
      );
    });

    test(
      'completedTargetFrames evaluates renderedFrames >= targetFrameCount',
      () {
        expect(
          _createDisposedReport({
            'targetFrameCount': 30,
            'renderedFrames': 15,
          }).completedTargetFrames,
          isFalse,
        );
        expect(
          _createDisposedReport({
            'targetFrameCount': 30,
            'renderedFrames': 30,
          }).completedTargetFrames,
          isTrue,
        );
        expect(
          _createDisposedReport({
            'targetFrameCount': 30,
            'renderedFrames': 0,
          }).completedTargetFrames,
          isFalse,
        );
      },
    );

    test(
      'isCleanedUp checks all 4 teardown booleans for disposed/cleanup variants',
      () {
        expect(
          _createDisposedReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
          }).isCleanedUp,
          isTrue,
        );
        expect(
          _createDisposedReport({
            'sessionClosed': false,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createDisposedReport({
            'sessionClosed': true,
            'deviceClosed': false,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createDisposedReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': false,
            'nativeSessionDestroyed': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createDisposedReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': false,
          }).isCleanedUp,
          isFalse,
        );
      },
    );
  });

  group(
    'VGCamera2TextureNativeRenderLoopSmokeReport start/dispose MethodChannel contracts',
    () {
      Future<MethodCall> captureCall({
        required Future<Object?> Function(MethodChannel channel) action,
        Object? response,
      }) async {
        MethodCall? capturedCall;
        const channel = MethodChannel('test_vanguard_dispose_smoke_channel');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return response;
        });
        await action(channel);
        return capturedCall!;
      }

      test(
        'start invokes start method with frameCount 30 and omits blank cameraId',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  frameCount: 30,
                  channel: channel,
                ),
            response: {'textureId': 42, 'targetFrameCount': 30},
          );

          expect(
            call.method,
            equals(
              'startAndroidDagPhase3UnitMCameraTextureNativeRenderLoopSmoke',
            ),
          );
          final args = call.arguments as Map<Object?, Object?>;
          expect(args['frameCount'], equals(30));
          expect(args.containsKey('cameraId'), isFalse);
          expect(args['timeoutMs'], equals(10000));
          expect(args['maxWidth'], equals(640));
          expect(args['maxHeight'], equals(480));
        },
      );

      test(
        'start omits whitespace-only cameraId when frameCount is 30',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2TextureNativeRenderLoopSmokeReport.startAndroidCamera2TextureNativeRenderLoopSmoke(
                  cameraId: '   ',
                  frameCount: 30,
                  channel: channel,
                ),
            response: {'textureId': 42, 'targetFrameCount': 30},
          );

          final args = call.arguments as Map<Object?, Object?>;
          expect(args.containsKey('cameraId'), isFalse);
          expect(args['frameCount'], equals(30));
        },
      );

      test(
        'dispose returns false for active pending release and true after completion release',
        () async {
          const channel = MethodChannel('test_dispose_active_vs_completed');
          binaryMessenger.setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map<Object?, Object?>;
            if (args['textureId'] == 100) {
              // Active run: dispose requested while running, release deferred
              return {
                'pass': true,
                'textureId': 100,
                'surfaceProducerReleased': false,
                'raw':
                    'status=OK;dispose_requested_pending_completion;textureId=100',
              };
            } else if (args['textureId'] == 200) {
              // Completed run: release performed immediately
              return {
                'pass': true,
                'textureId': 200,
                'surfaceProducerReleased': true,
                'raw': 'status=OK;disposed=true;textureId=200',
              };
            }
            return null;
          });

          final activeResult =
              await VGCamera2TextureNativeRenderLoopSmokeReport.disposeAndroidCamera2TextureNativeRenderLoopSmoke(
                textureId: 100,
                channel: channel,
              );
          expect(activeResult, isFalse);

          final completedResult =
              await VGCamera2TextureNativeRenderLoopSmokeReport.disposeAndroidCamera2TextureNativeRenderLoopSmoke(
                textureId: 200,
                channel: channel,
              );
          expect(completedResult, isTrue);

          final nullResult =
              await VGCamera2TextureNativeRenderLoopSmokeReport.disposeAndroidCamera2TextureNativeRenderLoopSmoke(
                textureId: 999,
                channel: channel,
              );
          expect(nullResult, isFalse);
        },
      );
    },
  );
}
