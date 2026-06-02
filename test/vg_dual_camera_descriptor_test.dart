// vg_dual_camera_descriptor_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
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
    });

    test('2. VGPiPAnchor serialization', () {
      final map = const VGPiPLayoutDescriptor(anchor: VGPiPAnchor.topLeft).toMap();
      expect(map['anchor'], 'topLeft');

      final fromMap = VGPiPLayoutDescriptor.fromMap({'anchor': 'topLeft'});
      expect(fromMap?.anchor, VGPiPAnchor.topLeft);
    });

    test('3. VGPiPLayoutDescriptor.toMap/fromMap round trip', () {
      const layout = VGPiPLayoutDescriptor(
        anchor: VGPiPAnchor.topRight,
        widthFraction: 0.5,
        marginFraction: 0.02,
        cornerRadius: 16.0,
        opacity: 0.8,
      );
      final map = layout.toMap();
      final roundTrip = VGPiPLayoutDescriptor.fromMap(map);
      expect(roundTrip, layout);
    });

    test('4. VGDualCameraDescriptor.toMap/fromMap round trip with two standard VGClipDescriptors', () {
      final desc = VGDualCameraDescriptor(
        primaryClip: clipA,
        secondaryClip: clipB,
        layoutMode: VGDualCameraLayoutMode.pip,
        pipLayout: const VGPiPLayoutDescriptor(anchor: VGPiPAnchor.bottomLeft),
      );

      final map = desc.toMap();
      final roundTrip = VGDualCameraDescriptor.fromMap(map);

      expect(roundTrip, desc);
      expect(roundTrip?.primaryClip.id, 'clip-a');
      expect(roundTrip?.secondaryClip.id, 'clip-b');
    });

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
    });

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
}
