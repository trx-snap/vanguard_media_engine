// vg_dual_camera_descriptor_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VGDualCameraDescriptor & VGPiPLayoutDescriptor Tests', () {
    final clipA = VGClipDescriptor(
      id: 'clip-a',
      sourcePath: '/path/to/a.mp4',
      mediaKind: VGMediaKind.video,
      startTimeSeconds: 0.0,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      speed: 1.0,
    );

    final clipB = VGClipDescriptor(
      id: 'clip-b',
      sourcePath: '/path/to/b.mp4',
      mediaKind: VGMediaKind.video,
      startTimeSeconds: 0.0,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      speed: 1.0,
    );

    test('1. default PiP layout values', () {
      const layout = VGPiPLayoutDescriptor();
      expect(layout.anchor, VGPiPAnchor.bottomRight);
      expect(layout.widthFraction, 0.35);
      expect(layout.marginFraction, 0.018);
      expect(layout.cornerRadius, 24.0);
      expect(layout.opacity, 1.0);
      expect(layout.centerX, 0.5);
      expect(layout.centerY, 0.5);
      expect(layout.aspectRatio, 9.0 / 16.0);
    });

    test('2. VGPiPAnchor serialization and freeFloating support', () {
      final map = const VGPiPLayoutDescriptor(
        anchor: VGPiPAnchor.topLeft,
      ).toMap();
      expect(map['anchor'], 'topLeft');

      final fromMap = VGPiPLayoutDescriptor.fromMap({'anchor': 'topLeft'});
      expect(fromMap?.anchor, VGPiPAnchor.topLeft);

      // freeFloating anchor support
      final freeMap = const VGPiPLayoutDescriptor(
        anchor: VGPiPAnchor.freeFloating,
      ).toMap();
      expect(freeMap['anchor'], 'freeFloating');

      final fromFree = VGPiPLayoutDescriptor.fromMap({
        'anchor': 'freeFloating',
      });
      expect(fromFree?.anchor, VGPiPAnchor.freeFloating);

      // Unknown anchor falls back to bottomRight
      final fromUnknown = VGPiPLayoutDescriptor.fromMap({
        'anchor': 'someUnknownAnchor',
      });
      expect(fromUnknown?.anchor, VGPiPAnchor.bottomRight);
    });

    test(
      '3. VGPiPLayoutDescriptor.toMap/fromMap round trip including freeFloating and center geometry',
      () {
        const layout = VGPiPLayoutDescriptor(
          anchor: VGPiPAnchor.freeFloating,
          widthFraction: 0.5,
          marginFraction: 0.02,
          cornerRadius: 16.0,
          opacity: 0.8,
          centerX: 0.3,
          centerY: 0.7,
          aspectRatio: 1.0,
        );
        final map = layout.toMap();
        expect(map['anchor'], 'freeFloating');
        expect(map['centerX'], 0.3);
        expect(map['centerY'], 0.7);
        expect(map['aspectRatio'], 1.0);

        final roundTrip = VGPiPLayoutDescriptor.fromMap(map);
        expect(roundTrip, layout);
        expect(roundTrip?.anchor, VGPiPAnchor.freeFloating);
        expect(roundTrip?.centerX, 0.3);
        expect(roundTrip?.centerY, 0.7);
        expect(roundTrip?.aspectRatio, 1.0);
      },
    );

    test(
      '3b. VGPiPLayoutDescriptor copyWith and equality include new fields',
      () {
        const layout = VGPiPLayoutDescriptor();
        final updated = layout.copyWith(
          anchor: VGPiPAnchor.freeFloating,
          centerX: 0.4,
          centerY: 0.6,
          aspectRatio: 16.0 / 9.0,
        );

        expect(updated.anchor, VGPiPAnchor.freeFloating);
        expect(updated.widthFraction, layout.widthFraction);
        expect(updated.marginFraction, layout.marginFraction);
        expect(updated.cornerRadius, layout.cornerRadius);
        expect(updated.opacity, layout.opacity);
        expect(updated.centerX, 0.4);
        expect(updated.centerY, 0.6);
        expect(updated.aspectRatio, 16.0 / 9.0);

        // Equality and hashCode
        final same = const VGPiPLayoutDescriptor(
          anchor: VGPiPAnchor.freeFloating,
          centerX: 0.4,
          centerY: 0.6,
          aspectRatio: 16.0 / 9.0,
        );
        expect(updated, same);
        expect(updated.hashCode, same.hashCode);
        expect(updated, isNot(layout));
      },
    );

    test(
      '4. VGDualCameraDescriptor.toMap/fromMap round trip with two standard VGClipDescriptors',
      () {
        final desc = VGDualCameraDescriptor(
          primaryClip: clipA,
          secondaryClip: clipB,
          layoutMode: VGDualCameraLayoutMode.pip,
          pipLayout: const VGPiPLayoutDescriptor(
            anchor: VGPiPAnchor.bottomLeft,
          ),
        );

        final map = desc.toMap();
        final roundTrip = VGDualCameraDescriptor.fromMap(map);

        expect(roundTrip, desc);
        expect(roundTrip?.primaryClip.id, 'clip-a');
        expect(roundTrip?.secondaryClip.id, 'clip-b');
      },
    );

    test('5. invalid width fraction rejected', () {
      expect(
        () => VGPiPLayoutDescriptor(widthFraction: 0.01),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VGPiPLayoutDescriptor(widthFraction: 0.8),
        throwsA(isA<AssertionError>()),
      );

      final badMap1 = {'widthFraction': 0.01};
      expect(VGPiPLayoutDescriptor.fromMap(badMap1), isNull);

      final badMap2 = {'widthFraction': 0.8};
      expect(VGPiPLayoutDescriptor.fromMap(badMap2), isNull);

      // Non-numeric type
      expect(
        VGPiPLayoutDescriptor.fromMap({'widthFraction': 'not-a-num'}),
        isNull,
      );
    });

    test('6. invalid opacity rejected', () {
      expect(
        () => VGPiPLayoutDescriptor(opacity: -0.1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VGPiPLayoutDescriptor(opacity: 1.1),
        throwsA(isA<AssertionError>()),
      );
      expect(VGPiPLayoutDescriptor.fromMap({'opacity': -0.1}), isNull);
      expect(VGPiPLayoutDescriptor.fromMap({'opacity': 1.1}), isNull);
    });

    test('7. invalid negative margin/corner radius rejected', () {
      expect(
        () => VGPiPLayoutDescriptor(marginFraction: -0.01),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VGPiPLayoutDescriptor(cornerRadius: -1.0),
        throwsA(isA<AssertionError>()),
      );
      expect(VGPiPLayoutDescriptor.fromMap({'marginFraction': -0.01}), isNull);
      expect(VGPiPLayoutDescriptor.fromMap({'cornerRadius': -1.0}), isNull);
    });

    test(
      '7b. invalid centerX, centerY, aspectRatio rejected in constructor and fromMap',
      () {
        // centerX [0, 1]
        expect(
          () => VGPiPLayoutDescriptor(centerX: -0.01),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VGPiPLayoutDescriptor(centerX: 1.01),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VGPiPLayoutDescriptor(centerX: double.nan),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VGPiPLayoutDescriptor(centerX: double.infinity),
          throwsA(isA<AssertionError>()),
        );
        expect(VGPiPLayoutDescriptor.fromMap({'centerX': -0.01}), isNull);
        expect(VGPiPLayoutDescriptor.fromMap({'centerX': 1.01}), isNull);
        expect(VGPiPLayoutDescriptor.fromMap({'centerX': 'invalid'}), isNull);

        // centerY [0, 1]
        expect(
          () => VGPiPLayoutDescriptor(centerY: -0.01),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VGPiPLayoutDescriptor(centerY: 1.01),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VGPiPLayoutDescriptor(centerY: double.nan),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VGPiPLayoutDescriptor(centerY: double.infinity),
          throwsA(isA<AssertionError>()),
        );
        expect(VGPiPLayoutDescriptor.fromMap({'centerY': -0.01}), isNull);
        expect(VGPiPLayoutDescriptor.fromMap({'centerY': 1.01}), isNull);
        expect(VGPiPLayoutDescriptor.fromMap({'centerY': 'invalid'}), isNull);

        // aspectRatio finite and > 0
        expect(
          () => VGPiPLayoutDescriptor(aspectRatio: 0.0),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VGPiPLayoutDescriptor(aspectRatio: -1.0),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VGPiPLayoutDescriptor(aspectRatio: double.nan),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VGPiPLayoutDescriptor(aspectRatio: double.infinity),
          throwsA(isA<AssertionError>()),
        );
        expect(VGPiPLayoutDescriptor.fromMap({'aspectRatio': 0.0}), isNull);
        expect(VGPiPLayoutDescriptor.fromMap({'aspectRatio': -1.0}), isNull);
        expect(
          VGPiPLayoutDescriptor.fromMap({'aspectRatio': 'invalid'}),
          isNull,
        );
      },
    );

    test('8. primary/secondary clip IDs preserved', () {
      final desc = VGDualCameraDescriptor(
        primaryClip: clipA,
        secondaryClip: clipB,
      );
      expect(desc.primaryClip.id, 'clip-a');
      expect(desc.secondaryClip.id, 'clip-b');
    });

    test('9. no camera/MultiCam fields exist in serialized payload', () {
      final desc = VGDualCameraDescriptor(
        primaryClip: clipA,
        secondaryClip: clipB,
      );
      final map = desc.toMap();

      final str = map.toString();
      expect(str.contains('MultiCam'), false);
      expect(str.contains('camera'), false);
      expect(str.contains('AVCapture'), false);
    });

    test('10. rejects same clip ID for primary and secondary', () {
      expect(
        () => VGDualCameraDescriptor(primaryClip: clipA, secondaryClip: clipA),
        throwsA(isA<AssertionError>()),
      );

      final desc = VGDualCameraDescriptor(
        primaryClip: clipA,
        secondaryClip: clipB,
      );
      final map = desc.toMap();
      (map['secondaryClip'] as Map)['id'] = 'clip-a';
      expect(VGDualCameraDescriptor.fromMap(map), isNull);
    });
  });

  // ── Phase 7.x-C: devValidateDualCameraDescriptor bridge tests ─────────────

  group('VGEditorController.devValidateDualCameraDescriptor (Phase 7.x-C)', () {
    const channel = MethodChannel('vanguard_media_engine');

    final clipA = VGClipDescriptor(
      id: 'clip-a',
      sourcePath: '/path/to/a.mp4',
      mediaKind: VGMediaKind.video,
      startTimeSeconds: 0.0,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      speed: 1.0,
    );

    final clipB = VGClipDescriptor(
      id: 'clip-b',
      sourcePath: '/path/to/b.mp4',
      mediaKind: VGMediaKind.video,
      startTimeSeconds: 0.0,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      speed: 1.0,
    );

    late VGEditorDraft minimalDraft;

    setUp(() {
      minimalDraft = VGEditorDraft(id: 'test-draft', clips: [clipA]);
    });

    // Captured state for each test assertion.
    String? capturedMethod;
    Map<Object?, Object?>? capturedArgs;

    void setChannelHandler(Map<String, Object?> returnValue) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            capturedMethod = call.method;
            capturedArgs = call.arguments is Map
                ? Map<Object?, Object?>.from(call.arguments as Map)
                : null;
            return returnValue;
          });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      capturedMethod = null;
      capturedArgs = null;
    });

    test(
      '11. invokes dev_validateDualCameraDescriptor channel method',
      () async {
        setChannelHandler({'ok': true});

        final controller = VGEditorController(
          initialDraft: minimalDraft,
          channel: channel,
        );

        final descriptor = VGDualCameraDescriptor(
          primaryClip: clipA,
          secondaryClip: clipB,
        );

        await controller.devValidateDualCameraDescriptor(descriptor);

        expect(capturedMethod, 'dev_validateDualCameraDescriptor');

        controller.dispose();
      },
    );

    test(
      '12. payload contains descriptor key with primaryClip, secondaryClip, layoutMode, pipLayout',
      () async {
        setChannelHandler({'ok': true});

        final controller = VGEditorController(
          initialDraft: minimalDraft,
          channel: channel,
        );

        final descriptor = VGDualCameraDescriptor(
          primaryClip: clipA,
          secondaryClip: clipB,
          layoutMode: VGDualCameraLayoutMode.pip,
          pipLayout: const VGPiPLayoutDescriptor(anchor: VGPiPAnchor.topLeft),
        );

        await controller.devValidateDualCameraDescriptor(descriptor);

        expect(capturedArgs, isNotNull);
        final descriptorPayload = capturedArgs!['descriptor'] as Map?;
        expect(descriptorPayload, isNotNull);
        expect(descriptorPayload!.containsKey('primaryClip'), isTrue);
        expect(descriptorPayload.containsKey('secondaryClip'), isTrue);
        expect(descriptorPayload.containsKey('layoutMode'), isTrue);
        expect(descriptorPayload.containsKey('pipLayout'), isTrue);
        expect(descriptorPayload['layoutMode'], 'pip');

        // Confirm no camera/MultiCam fields in the payload.
        final payloadStr = descriptorPayload.toString();
        expect(payloadStr.contains('MultiCam'), isFalse);
        expect(payloadStr.contains('AVCapture'), isFalse);

        controller.dispose();
      },
    );

    test('13. native return map is passed through correctly', () async {
      final nativeResult = <String, Object?>{
        'ok': true,
        'nodeClass': 'VGDualCameraCompositorNode',
        'layoutMode': 'pip',
        'primaryClipId': 'clip-a',
        'secondaryClipId': 'clip-b',
      };
      setChannelHandler(nativeResult);

      final controller = VGEditorController(
        initialDraft: minimalDraft,
        channel: channel,
      );

      final descriptor = VGDualCameraDescriptor(
        primaryClip: clipA,
        secondaryClip: clipB,
      );

      final result = await controller.devValidateDualCameraDescriptor(
        descriptor,
      );

      expect(result['ok'], isTrue);
      expect(result['nodeClass'], 'VGDualCameraCompositorNode');
      expect(result['primaryClipId'], 'clip-a');
      expect(result['secondaryClipId'], 'clip-b');

      controller.dispose();
    });

    test('14. throws StateError after dispose', () async {
      setChannelHandler({'ok': true});

      final controller = VGEditorController(
        initialDraft: minimalDraft,
        channel: channel,
      );
      controller.dispose();

      final descriptor = VGDualCameraDescriptor(
        primaryClip: clipA,
        secondaryClip: clipB,
      );

      expect(
        () => controller.devValidateDualCameraDescriptor(descriptor),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ── Phase 7.x-E: devCreateDualCameraTexture / devDisposeDualCameraTexture ──

  group('VGEditorController.devCreateDualCameraTexture (Phase 7.x-E)', () {
    const channel = MethodChannel('vanguard_media_engine');

    final clipA = VGClipDescriptor(
      id: 'clip-a',
      sourcePath: '/path/to/a.mp4',
      mediaKind: VGMediaKind.video,
      startTimeSeconds: 0.0,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      speed: 1.0,
    );

    final clipB = VGClipDescriptor(
      id: 'clip-b',
      sourcePath: '/path/to/b.mp4',
      mediaKind: VGMediaKind.video,
      startTimeSeconds: 0.0,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      speed: 1.0,
    );

    late VGEditorDraft minimalDraft;

    setUp(() {
      minimalDraft = VGEditorDraft(id: 'test-draft', clips: [clipA]);
    });

    String? capturedMethod;
    Map<Object?, Object?>? capturedArgs;

    void setChannelHandler(Map<String, Object?> returnValue) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            capturedMethod = call.method;
            capturedArgs = call.arguments is Map
                ? Map<Object?, Object?>.from(call.arguments as Map)
                : null;
            return returnValue;
          });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      capturedMethod = null;
      capturedArgs = null;
    });

    test(
      '15. devCreateDualCameraTexture invokes dev_createDualCameraTexture',
      () async {
        setChannelHandler({'ok': true, 'textureId': 77});

        final controller = VGEditorController(
          initialDraft: minimalDraft,
          channel: channel,
        );

        final descriptor = VGDualCameraDescriptor(
          primaryClip: clipA,
          secondaryClip: clipB,
        );

        await controller.devCreateDualCameraTexture(descriptor);

        expect(capturedMethod, 'dev_createDualCameraTexture');

        controller.dispose();
      },
    );

    test('16. payload contains descriptor key', () async {
      setChannelHandler({'ok': true, 'textureId': 77});

      final controller = VGEditorController(
        initialDraft: minimalDraft,
        channel: channel,
      );

      final descriptor = VGDualCameraDescriptor(
        primaryClip: clipA,
        secondaryClip: clipB,
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: const VGPiPLayoutDescriptor(anchor: VGPiPAnchor.topLeft),
      );

      await controller.devCreateDualCameraTexture(descriptor);

      expect(capturedArgs, isNotNull);
      final descriptorPayload = capturedArgs!['descriptor'] as Map?;
      expect(descriptorPayload, isNotNull);
      expect(descriptorPayload!.containsKey('primaryClip'), isTrue);
      expect(descriptorPayload.containsKey('secondaryClip'), isTrue);
      expect(descriptorPayload.containsKey('layoutMode'), isTrue);
      expect(descriptorPayload['layoutMode'], 'pip');

      // No camera/MultiCam fields in payload.
      final payloadStr = descriptorPayload.toString();
      expect(payloadStr.contains('MultiCam'), isFalse);
      expect(payloadStr.contains('AVCapture'), isFalse);

      controller.dispose();
    });

    test('17. width and height forwarded only when provided', () async {
      setChannelHandler({'ok': true, 'textureId': 77});

      final controller = VGEditorController(
        initialDraft: minimalDraft,
        channel: channel,
      );

      final descriptor = VGDualCameraDescriptor(
        primaryClip: clipA,
        secondaryClip: clipB,
      );

      // Without width/height — keys must be absent.
      await controller.devCreateDualCameraTexture(descriptor);
      expect(capturedArgs?.containsKey('width'), isFalse);
      expect(capturedArgs?.containsKey('height'), isFalse);

      // With width/height — keys must be present.
      await controller.devCreateDualCameraTexture(
        descriptor,
        width: 1280,
        height: 720,
      );
      expect(capturedArgs?['width'], 1280);
      expect(capturedArgs?['height'], 720);

      controller.dispose();
    });

    test('18. return map passes through textureId', () async {
      final nativeResult = <String, Object?>{
        'ok': true,
        'textureId': 99,
        'nodeClass': 'VGDualCameraCompositorNode',
        'layoutMode': 'pip',
        'primaryClipId': 'clip-a',
        'secondaryClipId': 'clip-b',
      };
      setChannelHandler(nativeResult);

      final controller = VGEditorController(
        initialDraft: minimalDraft,
        channel: channel,
      );

      final descriptor = VGDualCameraDescriptor(
        primaryClip: clipA,
        secondaryClip: clipB,
      );

      final result = await controller.devCreateDualCameraTexture(descriptor);

      expect(result['textureId'], 99);
      expect(result['ok'], isTrue);
      expect(result['nodeClass'], 'VGDualCameraCompositorNode');

      controller.dispose();
    });

    test(
      '19. devCreateDualCameraTexture does NOT invoke updateTimeline or createTimelineTexture',
      () async {
        final called = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              called.add(call.method);
              return {'ok': true, 'textureId': 77};
            });

        final controller = VGEditorController(
          initialDraft: minimalDraft,
          channel: channel,
        );

        final descriptor = VGDualCameraDescriptor(
          primaryClip: clipA,
          secondaryClip: clipB,
        );

        await controller.devCreateDualCameraTexture(descriptor);

        expect(called, isNot(contains('updateTimeline')));
        expect(called, isNot(contains('createTimelineTexture')));

        controller.dispose();
      },
    );

    test(
      '20. devDisposeDualCameraTexture invokes dev_disposeDualCameraTexture',
      () async {
        setChannelHandler({'ok': true});

        final controller = VGEditorController(
          initialDraft: minimalDraft,
          channel: channel,
        );

        await controller.devDisposeDualCameraTexture();

        expect(capturedMethod, 'dev_disposeDualCameraTexture');

        controller.dispose();
      },
    );

    test(
      '21. devCreateDualCameraTexture throws StateError after dispose',
      () async {
        setChannelHandler({'ok': true, 'textureId': 77});

        final controller = VGEditorController(
          initialDraft: minimalDraft,
          channel: channel,
        );
        controller.dispose();

        final descriptor = VGDualCameraDescriptor(
          primaryClip: clipA,
          secondaryClip: clipB,
        );

        expect(
          () => controller.devCreateDualCameraTexture(descriptor),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      '22. no camera/MultiCam fields in serialized descriptor payload',
      () async {
        setChannelHandler({'ok': true, 'textureId': 77});

        final controller = VGEditorController(
          initialDraft: minimalDraft,
          channel: channel,
        );

        final descriptor = VGDualCameraDescriptor(
          primaryClip: clipA,
          secondaryClip: clipB,
        );

        await controller.devCreateDualCameraTexture(descriptor);

        final descriptorPayload = capturedArgs!['descriptor'] as Map?;
        expect(descriptorPayload, isNotNull);
        final payloadStr = descriptorPayload.toString();
        expect(payloadStr.contains('MultiCam'), isFalse);
        expect(payloadStr.contains('AVCapture'), isFalse);
        expect(payloadStr.contains('AVCaptureMultiCamSession'), isFalse);

        controller.dispose();
      },
    );
  }); // end devCreateDualCameraTexture group

  // ── Phase 7.x-K: VGSplitScreenLayoutDescriptor and splitScreen layoutMode ──

  group('VGSplitScreenLayoutDescriptor Tests (Phase 7.x-K)', () {
    final clipA = VGClipDescriptor(
      id: 'clip-a',
      sourcePath: '/path/to/a.mp4',
      mediaKind: VGMediaKind.video,
      startTimeSeconds: 0.0,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      speed: 1.0,
    );
    final clipB = VGClipDescriptor(
      id: 'clip-b',
      sourcePath: '/path/to/b.mp4',
      mediaKind: VGMediaKind.video,
      startTimeSeconds: 0.0,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      speed: 1.0,
    );

    test(
      '23. VGSplitScreenLayoutDescriptor default splitRatio = 0.5 and direction = topBottom',
      () {
        const layout = VGSplitScreenLayoutDescriptor();
        expect(layout.splitRatio, 0.5);
        expect(layout.direction, VGSplitScreenDirection.topBottom);
      },
    );

    test('24. VGSplitScreenLayoutDescriptor toMap/fromMap round-trip', () {
      const layout = VGSplitScreenLayoutDescriptor(splitRatio: 0.3);
      final map = layout.toMap();
      expect(map['splitRatio'], 0.3);
      expect(map['direction'], 'topBottom');

      final roundTrip = VGSplitScreenLayoutDescriptor.fromMap(map);
      expect(roundTrip, layout);
      expect(roundTrip?.splitRatio, 0.3);
      expect(roundTrip?.direction, VGSplitScreenDirection.topBottom);
    });

    test(
      '24b. VGSplitScreenDirection serialization, copyWith, and leftRight round-trip',
      () {
        const layout = VGSplitScreenLayoutDescriptor(
          splitRatio: 0.65,
          direction: VGSplitScreenDirection.leftRight,
        );
        final map = layout.toMap();
        expect(map['splitRatio'], 0.65);
        expect(map['direction'], 'leftRight');

        final roundTrip = VGSplitScreenLayoutDescriptor.fromMap(map);
        expect(roundTrip, layout);
        expect(roundTrip?.direction, VGSplitScreenDirection.leftRight);

        // Unknown direction falls back to topBottom
        final fromUnknown = VGSplitScreenLayoutDescriptor.fromMap({
          'splitRatio': 0.5,
          'direction': 'diagonal',
        });
        expect(fromUnknown?.direction, VGSplitScreenDirection.topBottom);

        // copyWith replaces direction
        final copy = layout.copyWith(
          direction: VGSplitScreenDirection.topBottom,
        );
        expect(copy.direction, VGSplitScreenDirection.topBottom);
        expect(copy.splitRatio, 0.65);

        // Equality and hashCode include direction
        expect(copy, isNot(layout));
        expect(copy.hashCode, isNot(layout.hashCode));
      },
    );

    test('25. VGSplitScreenLayoutDescriptor fromMap null/missing → null', () {
      expect(VGSplitScreenLayoutDescriptor.fromMap(null), isNull);
    });

    test('26. VGSplitScreenLayoutDescriptor rejects splitRatio < 0.2', () {
      expect(
        () => VGSplitScreenLayoutDescriptor(splitRatio: 0.1),
        throwsA(isA<AssertionError>()),
      );
      // fromMap out-of-range → null
      expect(
        VGSplitScreenLayoutDescriptor.fromMap({'splitRatio': 0.1}),
        isNull,
      );
      // Non-numeric splitRatio -> null
      expect(
        VGSplitScreenLayoutDescriptor.fromMap({'splitRatio': 'not-a-num'}),
        isNull,
      );
    });

    test('27. VGSplitScreenLayoutDescriptor rejects splitRatio > 0.8', () {
      expect(
        () => VGSplitScreenLayoutDescriptor(splitRatio: 0.9),
        throwsA(isA<AssertionError>()),
      );
      expect(
        VGSplitScreenLayoutDescriptor.fromMap({'splitRatio': 0.9}),
        isNull,
      );
      expect(
        () => VGSplitScreenLayoutDescriptor(splitRatio: double.nan),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => VGSplitScreenLayoutDescriptor(splitRatio: double.infinity),
        throwsA(isA<AssertionError>()),
      );
    });

    test(
      '28. VGDualCameraDescriptor round-trip with splitScreen layoutMode',
      () {
        final desc = VGDualCameraDescriptor(
          primaryClip: clipA,
          secondaryClip: clipB,
          layoutMode: VGDualCameraLayoutMode.splitScreen,
          splitLayout: const VGSplitScreenLayoutDescriptor(
            splitRatio: 0.6,
            direction: VGSplitScreenDirection.leftRight,
          ),
        );

        final map = desc.toMap();
        expect(map['layoutMode'], 'splitScreen');
        expect((map['splitLayout'] as Map)['splitRatio'], 0.6);
        expect((map['splitLayout'] as Map)['direction'], 'leftRight');

        final roundTrip = VGDualCameraDescriptor.fromMap(map);
        expect(roundTrip, desc);
        expect(roundTrip?.layoutMode, VGDualCameraLayoutMode.splitScreen);
        expect(roundTrip?.splitLayout.splitRatio, 0.6);
        expect(
          roundTrip?.splitLayout.direction,
          VGSplitScreenDirection.leftRight,
        );
      },
    );

    test(
      '29. PiP layoutMode unaffected by split-screen changes (regression)',
      () {
        final desc = VGDualCameraDescriptor(
          primaryClip: clipA,
          secondaryClip: clipB,
          layoutMode: VGDualCameraLayoutMode.pip,
          pipLayout: const VGPiPLayoutDescriptor(anchor: VGPiPAnchor.topLeft),
        );
        final map = desc.toMap();
        expect(map['layoutMode'], 'pip');
        final roundTrip = VGDualCameraDescriptor.fromMap(map);
        expect(roundTrip?.layoutMode, VGDualCameraLayoutMode.pip);
        expect(roundTrip?.pipLayout.anchor, VGPiPAnchor.topLeft);
      },
    );

    test(
      '30. serialized splitScreen payload has no camera/MultiCam fields',
      () {
        final desc = VGDualCameraDescriptor(
          primaryClip: clipA,
          secondaryClip: clipB,
          layoutMode: VGDualCameraLayoutMode.splitScreen,
        );
        final map = desc.toMap();
        final str = map.toString();
        expect(str.contains('MultiCam'), isFalse);
        expect(str.contains('camera'), isFalse);
        expect(str.contains('AVCapture'), isFalse);
      },
    );
  });
}
