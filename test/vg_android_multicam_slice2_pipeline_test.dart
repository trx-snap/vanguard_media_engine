// vg_android_multicam_slice2_pipeline_test.dart
// Vanguard Media Engine - Slice 2 Mechanical Verification Test
//
// Tests for Slice 2: Single Output Texture Preview Pipeline Wiring.
// Validates:
// 1. startMultiCamPreview response parsing for single-texture composited pipeline (backTextureId == null).
// 2. VGDualCameraPreview widget rendering behavior with single vs dual texture sessions.
// 3. updateMultiCamPreviewConfig and stopMultiCamPreview channel contracts.

import 'package:flutter/material.dart';
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

  group('Slice 2 - Single Output Texture Preview Pipeline Contract', () {
    const kFrontId = '1';
    const kBackId = '0';

    // Matches the exact payload returned by AndroidCamera2MultiCamPreviewCoordinator
    // in onCompositorPipelineStarted()
    const kCompositedVulkanResponse = <Object?, Object?>{
      'textureId': 101,
      'backTextureId': null,
      'outputWidth': 1080,
      'outputHeight': 1920,
      'frontDeviceId': kFrontId,
      'backDeviceId': kBackId,
      'backend': 'Vulkan',
    };

    const kCompositedGlesResponse = <Object?, Object?>{
      'textureId': 102,
      'backTextureId': null,
      'outputWidth': 1080,
      'outputHeight': 1920,
      'frontDeviceId': kFrontId,
      'backDeviceId': kBackId,
      'backend': 'GLES',
    };

    test('startMultiCamPreview parses single composited Vulkan texture session correctly', () async {
      responses['startMultiCamPreview'] = kCompositedVulkanResponse;

      final session = await VGCameraSession.startMultiCamPreview(
        frontDeviceId: kFrontId,
        backDeviceId: kBackId,
        width: 1080,
        height: 1920,
      );

      expect(session, isNotNull);
      expect(session!.textureId, equals(101));
      expect(session.backTextureId, isNull);
      expect(session.outputWidth, equals(1080));
      expect(session.outputHeight, equals(1920));
      expect(session.frontDeviceId, equals(kFrontId));
      expect(session.backDeviceId, equals(kBackId));
    });

    test('startMultiCamPreview parses single composited GLES fallback texture session correctly', () async {
      responses['startMultiCamPreview'] = kCompositedGlesResponse;

      final session = await VGCameraSession.startMultiCamPreview(
        frontDeviceId: kFrontId,
        backDeviceId: kBackId,
        width: 1080,
        height: 1920,
      );

      expect(session, isNotNull);
      expect(session!.textureId, equals(102));
      expect(session.backTextureId, isNull);
      expect(session.outputWidth, equals(1080));
      expect(session.outputHeight, equals(1920));
    });

    testWidgets('VGDualCameraPreview renders single Texture when backTextureId is null', (WidgetTester tester) async {
      const session = VGMultiCamRenderTextureSession(
        textureId: 42,
        outputWidth: 1080,
        outputHeight: 1920,
        backTextureId: null,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VGDualCameraPreview(
              session: session,
              gridOption: VGDualCameraGridOption.pip,
            ),
          ),
        ),
      );

      // Verify that exactly one Texture widget is present in the tree
      final textureFinder = find.byType(Texture);
      expect(textureFinder, findsOneWidget);

      final Texture textureWidget = tester.widget<Texture>(textureFinder);
      expect(textureWidget.textureId, equals(42));
    });

    testWidgets('VGDualCameraPreview renders two Textures when backTextureId is present (legacy fallback)', (WidgetTester tester) async {
      const session = VGMultiCamRenderTextureSession(
        textureId: 42,
        backTextureId: 43,
        outputWidth: 1080,
        outputHeight: 1920,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VGDualCameraPreview(
              session: session,
              gridOption: VGDualCameraGridOption.pip,
            ),
          ),
        ),
      );

      // In dual-texture mode, both textures are rendered in PiP
      final textureFinder = find.byType(Texture);
      expect(textureFinder, findsNWidgets(2));
    });

    testWidgets('VGDualCameraPreview defaults to BoxFit.contain in splitH layout', (WidgetTester tester) async {
      const session = VGMultiCamRenderTextureSession(
        textureId: 42,
        outputWidth: 1080,
        outputHeight: 1920,
        backTextureId: null,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VGDualCameraPreview(
              session: session,
              gridOption: VGDualCameraGridOption.splitH,
            ),
          ),
        ),
      );

      final fittedBoxFinder = find.byType(FittedBox);
      expect(fittedBoxFinder, findsOneWidget);

      final FittedBox box = tester.widget<FittedBox>(fittedBoxFinder);
      expect(box.fit, equals(BoxFit.contain));
    });

    testWidgets('VGDualCameraPreview defaults to BoxFit.contain in splitV layout', (WidgetTester tester) async {
      const session = VGMultiCamRenderTextureSession(
        textureId: 42,
        outputWidth: 1080,
        outputHeight: 1920,
        backTextureId: null,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VGDualCameraPreview(
              session: session,
              gridOption: VGDualCameraGridOption.splitV,
            ),
          ),
        ),
      );

      final fittedBoxFinder = find.byType(FittedBox);
      expect(fittedBoxFinder, findsOneWidget);

      final FittedBox box = tester.widget<FittedBox>(fittedBoxFinder);
      expect(box.fit, equals(BoxFit.contain));
    });

    test('stopMultiCamPreview dispatches method call correctly', () async {
      responses['stopMultiCamPreview'] = null;

      final result = await VGCameraSession.stopMultiCamPreview();
      expect(result, isNull);
      expect(log.length, equals(1));
      expect(log.first.method, equals('stopMultiCamPreview'));
      expect(log.first.arguments, isNull);
    });

    test('updateMultiCamPreviewConfig dispatches config map correctly', () async {
      responses['updateMultiCamPreviewConfig'] = null;

      const config = VGLivePreviewConfig(
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: VGPiPLayoutDescriptor(anchor: VGPiPAnchor.topRight),
      );

      await VGCameraSession.updateMultiCamPreviewConfig(config);

      expect(log.length, equals(1));
      expect(log.first.method, equals('updateMultiCamPreviewConfig'));
      final args = log.first.arguments as Map;
      expect(args['config'], isNotNull);
      final configMap = args['config'] as Map;
      expect(configMap['layoutMode'], equals('pip'));
      final pipLayoutMap = configMap['pipLayout'] as Map;
      expect(pipLayoutMap['anchor'], equals('topRight'));
    });
  });
}
