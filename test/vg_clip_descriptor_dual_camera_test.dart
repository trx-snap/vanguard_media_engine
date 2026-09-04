// vg_clip_descriptor_dual_camera_test.dart
// Phase 7.x-Q1 — Dual-Camera Descriptor Foundation tests.
//
// Validates:
//   1. Existing VGClipDescriptor without dualCamera serializes/deserializes unchanged.
//   2. VGClipDescriptor with dualCamera round-trips through toMap() / fromMap().
//   3. The nested production timeline payload does NOT contain 'primaryClip'.
//   4. The secondary clip survives round-trip through the nested payload.
//   5. toTimelineMap() emits secondaryClip, layoutMode, pipLayout, splitLayout.
//   6. fromTimelineMap(_:primaryClip:) reconstructs correctly.
//   7. copyWith with dualCamera sentinel works correctly.
//   8. Equality and hashCode include dualCamera.
//   9. Malformed 'dualCamera' key (not a map) causes fromMap() to return null.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';
import 'package:vanguard_media_engine/vg_dual_camera_descriptor.dart';

void main() {
  // ── Shared fixtures ──────────────────────────────────────────────────────────

  final primaryClip = VGClipDescriptor(
    id: 'primary-clip',
    sourcePath: '/media/primary.mp4',
    mediaKind: VGMediaKind.video,
    startTimeSeconds: 0.0,
    durationSeconds: 10.0,
    trimStartSeconds: 0.0,
    trimEndSeconds: 10.0,
    speed: 1.0,
  );

  final secondaryClip = VGClipDescriptor(
    id: 'secondary-clip',
    sourcePath: '/media/secondary.mp4',
    mediaKind: VGMediaKind.video,
    startTimeSeconds: 0.0,
    durationSeconds: 10.0,
    trimStartSeconds: 0.0,
    trimEndSeconds: 10.0,
    speed: 1.0,
  );

  final pipDualCamera = VGDualCameraDescriptor(
    primaryClip: primaryClip,
    secondaryClip: secondaryClip,
    layoutMode: VGDualCameraLayoutMode.pip,
    pipLayout: const VGPiPLayoutDescriptor(anchor: VGPiPAnchor.topLeft),
  );

  final splitDualCamera = VGDualCameraDescriptor(
    primaryClip: primaryClip,
    secondaryClip: secondaryClip,
    layoutMode: VGDualCameraLayoutMode.splitScreen,
    splitLayout: const VGSplitScreenLayoutDescriptor(splitRatio: 0.4),
  );

  // ── Group 1: Existing single-clip regression ─────────────────────────────────

  group('Q1-REG: VGClipDescriptor without dualCamera — regression', () {
    test('Q1-REG-1 single-clip toMap() does not emit dualCamera key', () {
      final map = primaryClip.toMap();
      expect(
        map.containsKey('dualCamera'),
        isFalse,
        reason: 'Single-stream clip must not emit dualCamera key',
      );
    });

    test('Q1-REG-2 single-clip fromMap() round-trip is unchanged', () {
      final map = primaryClip.toMap();
      final restored = VGClipDescriptor.fromMap(map);
      expect(restored, isNotNull);
      expect(restored!.id, primaryClip.id);
      expect(restored.sourcePath, primaryClip.sourcePath);
      expect(
        restored.dualCamera,
        isNull,
        reason: 'Restored single-stream clip must have null dualCamera',
      );
    });

    test('Q1-REG-3 single-clip equality and hashCode unchanged', () {
      final map = primaryClip.toMap();
      final restored = VGClipDescriptor.fromMap(map)!;
      expect(restored, primaryClip);
      expect(restored.hashCode, primaryClip.hashCode);
    });
  });

  // ── Group 2: VGClipDescriptor with dualCamera ─────────────────────────────

  group('Q1-DC: VGClipDescriptor with dualCamera field', () {
    test('Q1-DC-1 dualCamera field is null by default', () {
      expect(primaryClip.dualCamera, isNull);
    });

    test('Q1-DC-2 VGClipDescriptor accepts dualCamera in constructor', () {
      final clip = VGClipDescriptor(
        id: 'primary-clip',
        sourcePath: '/media/primary.mp4',
        durationSeconds: 10.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 10.0,
        dualCamera: pipDualCamera,
      );
      expect(clip.dualCamera, isNotNull);
      expect(clip.dualCamera!.layoutMode, VGDualCameraLayoutMode.pip);
    });

    test('Q1-DC-3 toMap() emits dualCamera key when non-null', () {
      final clip = VGClipDescriptor(
        id: 'primary-clip',
        sourcePath: '/media/primary.mp4',
        durationSeconds: 10.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 10.0,
        dualCamera: pipDualCamera,
      );
      final map = clip.toMap();
      expect(
        map.containsKey('dualCamera'),
        isTrue,
        reason: 'Clip with dualCamera must emit dualCamera key',
      );
    });

    test(
      'Q1-DC-4 nested dualCamera payload does NOT contain primaryClip key',
      () {
        final clip = VGClipDescriptor(
          id: 'primary-clip',
          sourcePath: '/media/primary.mp4',
          durationSeconds: 10.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
          dualCamera: pipDualCamera,
        );
        final map = clip.toMap();
        final dualCameraMap = map['dualCamera'] as Map?;
        expect(dualCameraMap, isNotNull);
        expect(
          dualCameraMap!.containsKey('primaryClip'),
          isFalse,
          reason:
              'Timeline wire payload must NOT contain primaryClip '
              '(the enclosing VGClipDescriptor IS the primary)',
        );
      },
    );

    test('Q1-DC-5 nested dualCamera payload contains secondaryClip', () {
      final clip = VGClipDescriptor(
        id: 'primary-clip',
        sourcePath: '/media/primary.mp4',
        durationSeconds: 10.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 10.0,
        dualCamera: pipDualCamera,
      );
      final map = clip.toMap();
      final dualCameraMap = map['dualCamera'] as Map?;
      expect(dualCameraMap!.containsKey('secondaryClip'), isTrue);
      final secondary = dualCameraMap['secondaryClip'] as Map?;
      expect(secondary, isNotNull);
      expect(secondary!['id'], 'secondary-clip');
    });

    test(
      'Q1-DC-6 nested dualCamera payload contains layoutMode, pipLayout, splitLayout',
      () {
        final clip = VGClipDescriptor(
          id: 'primary-clip',
          sourcePath: '/media/primary.mp4',
          durationSeconds: 10.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
          dualCamera: pipDualCamera,
        );
        final map = clip.toMap();
        final dualCameraMap = map['dualCamera'] as Map;
        expect(dualCameraMap.containsKey('layoutMode'), isTrue);
        expect(dualCameraMap.containsKey('pipLayout'), isTrue);
        expect(dualCameraMap.containsKey('splitLayout'), isTrue);
        expect(dualCameraMap['layoutMode'], 'pip');
      },
    );

    test(
      'Q1-DC-7 VGClipDescriptor.toMap/fromMap round-trip with PiP dualCamera',
      () {
        final clip = VGClipDescriptor(
          id: 'primary-clip',
          sourcePath: '/media/primary.mp4',
          durationSeconds: 10.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
          dualCamera: pipDualCamera,
        );
        final map = clip.toMap();
        final restored = VGClipDescriptor.fromMap(map);
        expect(
          restored,
          isNotNull,
          reason: 'fromMap must succeed for dual-camera clip',
        );
        expect(restored!.id, 'primary-clip');
        expect(restored.dualCamera, isNotNull);
        expect(restored.dualCamera!.layoutMode, VGDualCameraLayoutMode.pip);
        expect(restored.dualCamera!.secondaryClip.id, 'secondary-clip');
        expect(restored.dualCamera!.pipLayout.anchor, VGPiPAnchor.topLeft);
      },
    );

    test(
      'Q1-DC-8 VGClipDescriptor.toMap/fromMap round-trip with split-screen dualCamera',
      () {
        final clip = VGClipDescriptor(
          id: 'primary-clip',
          sourcePath: '/media/primary.mp4',
          durationSeconds: 10.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
          dualCamera: splitDualCamera,
        );
        final map = clip.toMap();
        final restored = VGClipDescriptor.fromMap(map);
        expect(restored, isNotNull);
        expect(
          restored!.dualCamera!.layoutMode,
          VGDualCameraLayoutMode.splitScreen,
        );
        expect(restored.dualCamera!.splitLayout.splitRatio, closeTo(0.4, 1e-9));
      },
    );

    test(
      'Q1-DC-9 primaryClip in restored dualCamera matches the enclosing clip',
      () {
        final clip = VGClipDescriptor(
          id: 'primary-clip',
          sourcePath: '/media/primary.mp4',
          durationSeconds: 10.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
          dualCamera: pipDualCamera,
        );
        final map = clip.toMap();
        final restored = VGClipDescriptor.fromMap(map)!;
        // The primaryClip inside the reconstructed dualCamera must match the
        // enclosing clip (minus the dualCamera field itself to avoid circularity).
        expect(restored.dualCamera!.primaryClip.id, restored.id);
        expect(
          restored.dualCamera!.primaryClip.sourcePath,
          restored.sourcePath,
        );
      },
    );

    test(
      'Q1-DC-10 secondary clip survives round-trip (sourcePath, trim, speed)',
      () {
        final customSecondary = VGClipDescriptor(
          id: 'secondary-clip',
          sourcePath: '/media/secondary.mov',
          mediaKind: VGMediaKind.image,
          startTimeSeconds: 0.0,
          durationSeconds: 8.0,
          trimStartSeconds: 1.0,
          trimEndSeconds: 7.0,
          speed: 0.5,
        );
        final desc = VGDualCameraDescriptor(
          primaryClip: primaryClip,
          secondaryClip: customSecondary,
          layoutMode: VGDualCameraLayoutMode.pip,
        );
        final clip = VGClipDescriptor(
          id: 'primary-clip',
          sourcePath: '/media/primary.mp4',
          durationSeconds: 10.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
          dualCamera: desc,
        );
        final restored = VGClipDescriptor.fromMap(clip.toMap())!;
        final restoredSecondary = restored.dualCamera!.secondaryClip;
        expect(restoredSecondary.sourcePath, '/media/secondary.mov');
        expect(restoredSecondary.mediaKind, VGMediaKind.image);
        expect(restoredSecondary.trimStartSeconds, closeTo(1.0, 1e-9));
        expect(restoredSecondary.trimEndSeconds, closeTo(7.0, 1e-9));
        expect(restoredSecondary.speed, closeTo(0.5, 1e-9));
      },
    );

    test(
      'Q1-DC-11 VGClipDescriptor.toMap/fromMap preserves freeFloating PiP center geometry and aspectRatio',
      () {
        final freeFloatingDesc = VGDualCameraDescriptor(
          primaryClip: primaryClip,
          secondaryClip: secondaryClip,
          layoutMode: VGDualCameraLayoutMode.pip,
          pipLayout: const VGPiPLayoutDescriptor(
            anchor: VGPiPAnchor.freeFloating,
            centerX: 0.35,
            centerY: 0.65,
            aspectRatio: 1.0,
          ),
        );
        final clip = VGClipDescriptor(
          id: 'primary-clip',
          sourcePath: '/media/primary.mp4',
          durationSeconds: 10.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
          dualCamera: freeFloatingDesc,
        );
        final map = clip.toMap();
        final restored = VGClipDescriptor.fromMap(map);
        expect(restored, isNotNull);
        expect(
          restored!.dualCamera!.pipLayout.anchor,
          VGPiPAnchor.freeFloating,
        );
        expect(restored.dualCamera!.pipLayout.centerX, 0.35);
        expect(restored.dualCamera!.pipLayout.centerY, 0.65);
        expect(restored.dualCamera!.pipLayout.aspectRatio, 1.0);
      },
    );

    test(
      'Q1-DC-12 VGClipDescriptor.toMap/fromMap preserves directional leftRight splitScreen',
      () {
        final leftRightDesc = VGDualCameraDescriptor(
          primaryClip: primaryClip,
          secondaryClip: secondaryClip,
          layoutMode: VGDualCameraLayoutMode.splitScreen,
          splitLayout: const VGSplitScreenLayoutDescriptor(
            splitRatio: 0.65,
            direction: VGSplitScreenDirection.leftRight,
          ),
        );
        final clip = VGClipDescriptor(
          id: 'primary-clip',
          sourcePath: '/media/primary.mp4',
          durationSeconds: 10.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
          dualCamera: leftRightDesc,
        );
        final map = clip.toMap();
        final restored = VGClipDescriptor.fromMap(map);
        expect(restored, isNotNull);
        expect(
          restored!.dualCamera!.layoutMode,
          VGDualCameraLayoutMode.splitScreen,
        );
        expect(
          restored.dualCamera!.splitLayout.splitRatio,
          closeTo(0.65, 1e-9),
        );
        expect(
          restored.dualCamera!.splitLayout.direction,
          VGSplitScreenDirection.leftRight,
        );
      },
    );
  });

  // ── Group 3: toTimelineMap / fromTimelineMap direct tests ───────────────────

  group('Q1-TM: VGDualCameraDescriptor.toTimelineMap / fromTimelineMap', () {
    test('Q1-TM-1 toTimelineMap omits primaryClip', () {
      final tlMap = pipDualCamera.toTimelineMap();
      expect(
        tlMap.containsKey('primaryClip'),
        isFalse,
        reason: 'toTimelineMap must not include primaryClip',
      );
    });

    test(
      'Q1-TM-2 toTimelineMap includes secondaryClip, layoutMode, pipLayout, splitLayout',
      () {
        final tlMap = pipDualCamera.toTimelineMap();
        expect(tlMap.containsKey('secondaryClip'), isTrue);
        expect(tlMap.containsKey('layoutMode'), isTrue);
        expect(tlMap.containsKey('pipLayout'), isTrue);
        expect(tlMap.containsKey('splitLayout'), isTrue);
      },
    );

    test(
      'Q1-TM-3 fromTimelineMap reconstructs descriptor with supplied primary',
      () {
        final tlMap = pipDualCamera.toTimelineMap();
        final reconstructed = VGDualCameraDescriptor.fromTimelineMap(
          tlMap,
          primaryClip: primaryClip,
        );
        expect(reconstructed, isNotNull);
        expect(reconstructed!.primaryClip.id, 'primary-clip');
        expect(reconstructed.secondaryClip.id, 'secondary-clip');
        expect(reconstructed.layoutMode, VGDualCameraLayoutMode.pip);
      },
    );

    test('Q1-TM-4 fromTimelineMap returns null when secondaryClip missing', () {
      final badMap = <Object?, Object?>{
        'layoutMode': 'pip',
        'pipLayout': const VGPiPLayoutDescriptor().toMap(),
        'splitLayout': const VGSplitScreenLayoutDescriptor().toMap(),
      };
      final result = VGDualCameraDescriptor.fromTimelineMap(
        badMap,
        primaryClip: primaryClip,
      );
      expect(
        result,
        isNull,
        reason:
            'fromTimelineMap must return null when secondaryClip is missing',
      );
    });

    test(
      'Q1-TM-5 fromTimelineMap returns null when primary and secondary IDs match',
      () {
        final badDesc = VGDualCameraDescriptor(
          primaryClip: primaryClip,
          secondaryClip: secondaryClip, // valid at construction
        );
        // Manually craft a map that has a secondary with the same ID as primary.
        final tlMap = badDesc.toTimelineMap();
        final secondaryMap = Map<Object?, Object?>.from(
          tlMap['secondaryClip'] as Map<Object?, Object?>,
        );
        secondaryMap['id'] = primaryClip.id; // force same ID
        final corruptMap = {
          'secondaryClip': secondaryMap,
          'layoutMode': tlMap['layoutMode'],
          'pipLayout': tlMap['pipLayout'],
          'splitLayout': tlMap['splitLayout'],
        };
        final result = VGDualCameraDescriptor.fromTimelineMap(
          corruptMap,
          primaryClip: primaryClip,
        );
        expect(
          result,
          isNull,
          reason: 'Same-ID primary/secondary must be rejected',
        );
      },
    );

    test(
      'Q1-TM-6 toTimelineMap -> fromTimelineMap round-trip for splitScreen',
      () {
        final tlMap = splitDualCamera.toTimelineMap();
        final reconstructed = VGDualCameraDescriptor.fromTimelineMap(
          tlMap,
          primaryClip: primaryClip,
        );
        expect(reconstructed!.layoutMode, VGDualCameraLayoutMode.splitScreen);
        expect(reconstructed.splitLayout.splitRatio, closeTo(0.4, 1e-9));
      },
    );

    test(
      'Q1-TM-7 toTimelineMap -> fromTimelineMap preserves freeFloating PiP and omits primaryClip',
      () {
        final freeFloatingDesc = VGDualCameraDescriptor(
          primaryClip: primaryClip,
          secondaryClip: secondaryClip,
          layoutMode: VGDualCameraLayoutMode.pip,
          pipLayout: const VGPiPLayoutDescriptor(
            anchor: VGPiPAnchor.freeFloating,
            centerX: 0.35,
            centerY: 0.65,
            aspectRatio: 1.0,
          ),
        );
        final tlMap = freeFloatingDesc.toTimelineMap();

        // Ensure primaryClip is omitted from timeline wire map
        expect(tlMap.containsKey('primaryClip'), isFalse);

        final reconstructed = VGDualCameraDescriptor.fromTimelineMap(
          tlMap,
          primaryClip: primaryClip,
        );
        expect(reconstructed, isNotNull);
        expect(reconstructed!.pipLayout.anchor, VGPiPAnchor.freeFloating);
        expect(reconstructed.pipLayout.centerX, 0.35);
        expect(reconstructed.pipLayout.centerY, 0.65);
        expect(reconstructed.pipLayout.aspectRatio, 1.0);
      },
    );

    test(
      'Q1-TM-8 toTimelineMap -> fromTimelineMap preserves directional leftRight splitScreen and omits primaryClip',
      () {
        final leftRightDesc = VGDualCameraDescriptor(
          primaryClip: primaryClip,
          secondaryClip: secondaryClip,
          layoutMode: VGDualCameraLayoutMode.splitScreen,
          splitLayout: const VGSplitScreenLayoutDescriptor(
            splitRatio: 0.65,
            direction: VGSplitScreenDirection.leftRight,
          ),
        );
        final tlMap = leftRightDesc.toTimelineMap();

        // Ensure primaryClip is omitted from timeline wire map
        expect(tlMap.containsKey('primaryClip'), isFalse);

        final reconstructed = VGDualCameraDescriptor.fromTimelineMap(
          tlMap,
          primaryClip: primaryClip,
        );
        expect(reconstructed, isNotNull);
        expect(reconstructed!.layoutMode, VGDualCameraLayoutMode.splitScreen);
        expect(reconstructed.splitLayout.splitRatio, closeTo(0.65, 1e-9));
        expect(
          reconstructed.splitLayout.direction,
          VGSplitScreenDirection.leftRight,
        );
      },
    );
  });

  // ── Group 4: copyWith sentinel for dualCamera ───────────────────────────────

  group('Q1-CW: copyWith with dualCamera sentinel', () {
    final clipWithDualCamera = VGClipDescriptor(
      id: 'primary-clip',
      sourcePath: '/media/primary.mp4',
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      dualCamera: pipDualCamera,
    );

    test(
      'Q1-CW-1 copyWith without dualCamera arg preserves existing dualCamera',
      () {
        final copy = clipWithDualCamera.copyWith(speed: 1.0);
        expect(copy.dualCamera, isNotNull);
        expect(copy.dualCamera!.layoutMode, VGDualCameraLayoutMode.pip);
      },
    );

    test('Q1-CW-2 copyWith with dualCamera: null clears dualCamera', () {
      final copy = clipWithDualCamera.copyWith(dualCamera: null);
      expect(copy.dualCamera, isNull);
    });

    test('Q1-CW-3 copyWith replaces dualCamera with new descriptor', () {
      final copy = clipWithDualCamera.copyWith(dualCamera: splitDualCamera);
      expect(copy.dualCamera!.layoutMode, VGDualCameraLayoutMode.splitScreen);
    });

    test('Q1-CW-4 copyWith on clip without dualCamera leaves it null', () {
      final copy = primaryClip.copyWith(speed: 1.0);
      expect(copy.dualCamera, isNull);
    });
  });

  // ── Group 5: Equality and hashCode ─────────────────────────────────────────

  group('Q1-EQ: equality and hashCode include dualCamera', () {
    test('Q1-EQ-1 clips differ only in dualCamera are not equal', () {
      final clipA = VGClipDescriptor(
        id: 'primary-clip',
        sourcePath: '/media/primary.mp4',
        durationSeconds: 10.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 10.0,
      );
      final clipB = VGClipDescriptor(
        id: 'primary-clip',
        sourcePath: '/media/primary.mp4',
        durationSeconds: 10.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 10.0,
        dualCamera: pipDualCamera,
      );
      expect(
        clipA == clipB,
        isFalse,
        reason: 'Clips differing only in dualCamera must not be equal',
      );
      expect(
        clipA.hashCode == clipB.hashCode,
        isFalse,
        reason: 'hashCodes should differ when dualCamera differs',
      );
    });

    test('Q1-EQ-2 two clips with identical dualCamera are equal', () {
      final clipA = VGClipDescriptor(
        id: 'primary-clip',
        sourcePath: '/media/primary.mp4',
        durationSeconds: 10.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 10.0,
        dualCamera: pipDualCamera,
      );
      final clipB = VGClipDescriptor(
        id: 'primary-clip',
        sourcePath: '/media/primary.mp4',
        durationSeconds: 10.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 10.0,
        dualCamera: pipDualCamera,
      );
      expect(clipA, clipB);
      expect(clipA.hashCode, clipB.hashCode);
    });
  });

  // ── Group 6: Malformed dualCamera fromMap guard ─────────────────────────────

  group('Q1-GUARD: fromMap rejects malformed dualCamera', () {
    test(
      'Q1-GUARD-1 dualCamera key present but not a Map causes fromMap to return null',
      () {
        final map = <String, Object?>{
          'id': 'primary-clip',
          'sourcePath': '/media/primary.mp4',
          'mediaKind': 'video',
          'startTimeSeconds': 0.0,
          'durationSeconds': 10.0,
          'trimStartSeconds': 0.0,
          'trimEndSeconds': 10.0,
          'speed': 1.0,
          'dualCamera': 'not-a-map', // wrong type
        };
        final result = VGClipDescriptor.fromMap(map);
        expect(
          result,
          isNull,
          reason: 'Non-Map dualCamera value must cause fromMap to return null',
        );
      },
    );

    test(
      'Q1-GUARD-2 dualCamera key with missing secondaryClip causes fromMap to return null',
      () {
        final map = <Object?, Object?>{
          'id': 'primary-clip',
          'sourcePath': '/media/primary.mp4',
          'mediaKind': 'video',
          'startTimeSeconds': 0.0,
          'durationSeconds': 10.0,
          'trimStartSeconds': 0.0,
          'trimEndSeconds': 10.0,
          'speed': 1.0,
          'dualCamera': <Object?, Object?>{
            // missing 'secondaryClip' key
            'layoutMode': 'pip',
          },
        };
        final result = VGClipDescriptor.fromMap(map);
        expect(
          result,
          isNull,
          reason:
              'Missing secondaryClip in dualCamera payload must cause fromMap to return null',
        );
      },
    );

    test(
      'Q1-GUARD-3 absent dualCamera key leaves field null (normal clip)',
      () {
        final map = <Object?, Object?>{
          'id': 'primary-clip',
          'sourcePath': '/media/primary.mp4',
          'mediaKind': 'video',
          'startTimeSeconds': 0.0,
          'durationSeconds': 10.0,
          'trimStartSeconds': 0.0,
          'trimEndSeconds': 10.0,
          'speed': 1.0,
          // no 'dualCamera' key
        };
        final result = VGClipDescriptor.fromMap(map);
        expect(result, isNotNull);
        expect(result!.dualCamera, isNull);
      },
    );
  });

  // ── Group 7: DEV toMap() regression guard ──────────────────────────────────

  group('Q1-DEV: VGDualCameraDescriptor.toMap DEV behavior unchanged', () {
    test('Q1-DEV-1 toMap() still emits primaryClip (DEV route unchanged)', () {
      final devMap = pipDualCamera.toMap();
      expect(
        devMap.containsKey('primaryClip'),
        isTrue,
        reason:
            'DEV toMap must continue to emit primaryClip for existing DEV routes',
      );
    });

    test('Q1-DEV-2 fromMap() still round-trips including primaryClip', () {
      final devMap = pipDualCamera.toMap();
      final restored = VGDualCameraDescriptor.fromMap(devMap);
      expect(restored, isNotNull);
      expect(restored, pipDualCamera);
    });
  });
}
