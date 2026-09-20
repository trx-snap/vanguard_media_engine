// vg_android_multicam_slice3_layout_test.dart
// Vanguard Media Engine - Slice 3 Mechanical Verification Test
//
// Tests for Slice 3: Dynamic Layout Switching in Android Compositor.
// Validates:
// 1. startMultiCamPreview forwards initial VGLivePreviewConfig across MethodChannel.
// 2. updateMultiCamPreviewConfig forwards PiP and SplitScreen configurations with exact keys
//    matching AndroidDualCameraCompositor.parseConfigMap() expectations.
// 3. Verifies splitLayout 'direction' key contract (mapped to splitDirection in Kotlin LayoutParams).
// 4. Verifies freeFloating PiP coordinates (centerX, centerY, widthFraction).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('vanguard_media_engine');
  final List<MethodCall> log = <MethodCall>[];
  final Map<String, dynamic> responses = <String, dynamic>{};

  setUp(() {
    log.clear();
    responses.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);
      if (responses.containsKey(methodCall.method)) {
        final dynamic resp = responses[methodCall.method];
        if (resp is Exception) throw resp;
        return resp;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('Slice 3 - Dynamic Layout Switching Pipeline Contracts', () {
    const kFrontId = '1';
    const kBackId = '0';

    const kSuccessPreviewResponse = <Object?, Object?>{
      'textureId': 201,
      'backTextureId': null,
      'outputWidth': 1080,
      'outputHeight': 1920,
      'frontDeviceId': kFrontId,
      'backDeviceId': kBackId,
      'backend': 'Vulkan',
    };

    // ── 1. Initial Config on startMultiCamPreview ──────────────────────────

    test('startMultiCamPreview forwards initial split-screen config in arguments', () async {
      responses['startMultiCamPreview'] = kSuccessPreviewResponse;

      const initialConfig = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.splitScreen,
        splitLayout: VGSplitScreenLayoutDescriptor(
          splitRatio: 0.6,
          direction: VGSplitScreenDirection.leftRight,
        ),
      );

      final session = await VGCameraSession.startMultiCamPreview(
        frontDeviceId: kFrontId,
        backDeviceId: kBackId,
        width: 1080,
        height: 1920,
        config: initialConfig,
      );

      expect(session, isNotNull);
      expect(session!.textureId, equals(201));
      expect(log.length, equals(1));
      expect(log.first.method, equals('startMultiCamPreview'));

      final args = log.first.arguments as Map;
      expect(args['frontDeviceId'], equals(kFrontId));
      expect(args['backDeviceId'], equals(kBackId));
      expect(args['width'], equals(1080));
      expect(args['height'], equals(1920));
      expect(args.containsKey('config'), isTrue,
          reason: 'config must be forwarded when provided');

      final configMap = args['config'] as Map;
      expect(configMap['layoutMode'], equals('splitScreen'));

      final splitMap = configMap['splitLayout'] as Map;
      expect(splitMap['splitRatio'], equals(0.6));
      expect(splitMap['direction'], equals('leftRight'),
          reason: 'Dart key must be "direction" for Kotlin parseConfigMap');
    });

    test('startMultiCamPreview omits config argument when null', () async {
      responses['startMultiCamPreview'] = kSuccessPreviewResponse;

      final session = await VGCameraSession.startMultiCamPreview(
        frontDeviceId: kFrontId,
        backDeviceId: kBackId,
        width: 1080,
        height: 1920,
      );

      expect(session, isNotNull);
      expect(log.length, equals(1));
      final args = log.first.arguments as Map;
      expect(args.containsKey('config'), isFalse,
          reason: 'config key should not be present when config is null');
    });

    // ── 2. updateMultiCamPreviewConfig with Split Screen ─────────────────

    test('updateMultiCamPreviewConfig sends splitScreen config with direction and splitRatio', () async {
      responses['updateMultiCamPreviewConfig'] = null;

      const splitConfig = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.splitScreen,
        splitLayout: VGSplitScreenLayoutDescriptor(
          splitRatio: 0.55,
          direction: VGSplitScreenDirection.topBottom,
        ),
      );

      await VGCameraSession.updateMultiCamPreviewConfig(splitConfig);

      expect(log.length, equals(1));
      expect(log.first.method, equals('updateMultiCamPreviewConfig'));

      final args = log.first.arguments as Map;
      expect(args.containsKey('config'), isTrue);

      final configMap = args['config'] as Map;
      expect(configMap['layoutMode'], equals('splitScreen'));

      final splitMap = configMap['splitLayout'] as Map;
      expect(splitMap['direction'], equals('topBottom'));
      expect(splitMap['splitRatio'], equals(0.55));
    });

    // ── 3. updateMultiCamPreviewConfig with PiP (Standard & FreeFloating) ─

    test('updateMultiCamPreviewConfig sends standard PiP config with anchor and widthFraction', () async {
      responses['updateMultiCamPreviewConfig'] = null;

      const pipConfig = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: VGPiPLayoutDescriptor(
          anchor: VGPiPAnchor.bottomLeft,
          widthFraction: 0.28,
        ),
      );

      await VGCameraSession.updateMultiCamPreviewConfig(pipConfig);

      expect(log.length, equals(1));
      final args = log.first.arguments as Map;
      final configMap = args['config'] as Map;
      expect(configMap['layoutMode'], equals('pip'));

      final pipMap = configMap['pipLayout'] as Map;
      expect(pipMap['anchor'], equals('bottomLeft'));
      expect(pipMap['widthFraction'], equals(0.28));
    });

    test('updateMultiCamPreviewConfig sends freeFloating PiP with center coordinates', () async {
      responses['updateMultiCamPreviewConfig'] = null;

      const freeFloatingConfig = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: VGPiPLayoutDescriptor(
          anchor: VGPiPAnchor.freeFloating,
          centerX: 0.42,
          centerY: 0.68,
          widthFraction: 0.35,
        ),
      );

      await VGCameraSession.updateMultiCamPreviewConfig(freeFloatingConfig);

      expect(log.length, equals(1));
      final args = log.first.arguments as Map;
      final configMap = args['config'] as Map;
      expect(configMap['layoutMode'], equals('pip'));

      final pipMap = configMap['pipLayout'] as Map;
      expect(pipMap['anchor'], equals('freeFloating'));
      expect(pipMap['centerX'], equals(0.42));
      expect(pipMap['centerY'], equals(0.68));
      expect(pipMap['widthFraction'], equals(0.35));
    });

    // ── 4. Error Handling ──────────────────────────────────────────────────

    test('updateMultiCamPreviewConfig swallows PlatformException (fail-safe)', () async {
      responses['updateMultiCamPreviewConfig'] = PlatformException(
        code: 'NOT_RUNNING',
        message: 'Android MultiCam preview is not running',
      );

      const config = VGLivePreviewConfig();
      // Should complete normally without throwing
      await expectLater(
        VGCameraSession.updateMultiCamPreviewConfig(config),
        completes,
      );
    });
  });
}
