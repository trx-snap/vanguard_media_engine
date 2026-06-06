// vg_canvas_descriptor_test.dart
// Vanguard Media Engine — Phase 8.1
//
// Pure Dart unit tests for VGCanvasDescriptor and VGCanvasContentMode.
//
// Coverage:
//   CD-1  to CD-5   — Default descriptor construction and field values
//   CD-6  to CD-10  — toMap() output shape and omit-when-zero behaviour
//   CD-11 to CD-15  — fromMap() round-trip
//   CD-16 to CD-18  — fromMap() invalid / missing width/height → defaults
//   CD-19 to CD-21  — fromMap() negative safe-area → clamped to 0
//   CD-22 to CD-24  — fromMap() invalid/missing backgroundColor → default
//   CD-25 to CD-27  — fromMap() out-of-range backgroundColor → clamped
//   CD-28 to CD-30  — fromMap() unknown contentMode → fit
//   CD-31 to CD-33  — All contentMode enum values serialize/deserialize
//   CD-34 to CD-36  — copyWith behaviour
//   CD-37 to CD-39  — Equality and hashCode
//   CD-40           — null map returns null from fromMap()
//
// No Flutter engine or native code required — runs with:
//   dart test test/vg_canvas_descriptor_test.dart
// (from packages/vanguard_media_engine/)

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_canvas_descriptor.dart';

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // Default descriptor
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — default values', () {
    late VGCanvasDescriptor canvas;

    setUp(() {
      canvas = VGCanvasDescriptor();
    });

    test('CD-1  default width is 1080', () {
      expect(canvas.width, 1080);
    });

    test('CD-2  default height is 1920', () {
      expect(canvas.height, 1920);
    });

    test('CD-3  default contentMode is fit', () {
      expect(canvas.contentMode, VGCanvasContentMode.fit);
    });

    test('CD-4  default backgroundColor is [0,0,0,1] (opaque black)', () {
      expect(canvas.backgroundColor, [0.0, 0.0, 0.0, 1.0]);
    });

    test('CD-5  default safe-area insets are all 0', () {
      expect(canvas.safeAreaTop, 0.0);
      expect(canvas.safeAreaBottom, 0.0);
      expect(canvas.safeAreaLeft, 0.0);
      expect(canvas.safeAreaRight, 0.0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // toMap() output shape
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — toMap() output shape', () {
    test('CD-6  toMap() includes required keys', () {
      final m = VGCanvasDescriptor().toMap();
      expect(m.containsKey('width'), isTrue);
      expect(m.containsKey('height'), isTrue);
      expect(m.containsKey('contentMode'), isTrue);
      expect(m.containsKey('backgroundColor'), isTrue);
    });

    test('CD-7  toMap() width and height are correct', () {
      final m = VGCanvasDescriptor(width: 720, height: 1280).toMap();
      expect(m['width'], 720);
      expect(m['height'], 1280);
    });

    test('CD-8  toMap() omits safeArea keys when all zero', () {
      final m = VGCanvasDescriptor().toMap();
      expect(m.containsKey('safeAreaTop'),    isFalse);
      expect(m.containsKey('safeAreaBottom'), isFalse);
      expect(m.containsKey('safeAreaLeft'),   isFalse);
      expect(m.containsKey('safeAreaRight'),  isFalse);
    });

    test('CD-9  toMap() includes safeArea keys when non-zero', () {
      final canvas = VGCanvasDescriptor(
        safeAreaTop: 44.0,
        safeAreaBottom: 34.0,
        safeAreaLeft: 0.0,
        safeAreaRight: 0.0,
      );
      final m = canvas.toMap();
      expect(m['safeAreaTop'],    44.0);
      expect(m['safeAreaBottom'], 34.0);
      expect(m.containsKey('safeAreaLeft'),  isFalse);
      expect(m.containsKey('safeAreaRight'), isFalse);
    });

    test('CD-10 toMap() contentMode serializes as wire string', () {
      expect(VGCanvasDescriptor().toMap()['contentMode'], 'fit');
      expect(
        VGCanvasDescriptor(contentMode: VGCanvasContentMode.fill)
            .toMap()['contentMode'],
        'fill',
      );
      expect(
        VGCanvasDescriptor(contentMode: VGCanvasContentMode.stretch)
            .toMap()['contentMode'],
        'stretch',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // fromMap() round-trip
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — fromMap() round-trip', () {
    test('CD-11 default descriptor round-trips correctly', () {
      final original = VGCanvasDescriptor();
      final m = original.toMap();
      final clone = VGCanvasDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clone, isNotNull);
      expect(clone!.width, original.width);
      expect(clone.height, original.height);
      expect(clone.contentMode, original.contentMode);
      expect(clone.backgroundColor, original.backgroundColor);
      expect(clone.safeAreaTop, original.safeAreaTop);
      expect(clone.safeAreaBottom, original.safeAreaBottom);
      expect(clone.safeAreaLeft, original.safeAreaLeft);
      expect(clone.safeAreaRight, original.safeAreaRight);
    });

    test('CD-12 custom descriptor with all fields round-trips', () {
      final original = VGCanvasDescriptor(
        width: 1080,
        height: 1920,
        contentMode: VGCanvasContentMode.fill,
        backgroundColor: [0.1, 0.2, 0.3, 0.9],
        safeAreaTop: 44.0,
        safeAreaBottom: 34.0,
        safeAreaLeft: 8.0,
        safeAreaRight: 8.0,
      );
      final clone = VGCanvasDescriptor.fromMap(
        Map<Object?, Object?>.from(original.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!, original);
    });

    test('CD-13 fromMap() on map with no safeArea keys produces 0 insets', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.safeAreaTop, 0.0);
      expect(canvas.safeAreaBottom, 0.0);
      expect(canvas.safeAreaLeft, 0.0);
      expect(canvas.safeAreaRight, 0.0);
    });

    test('CD-14 fromMap() preserves backgroundColor components', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [0.5, 0.25, 0.75, 0.8],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.backgroundColor[0], closeTo(0.5, 1e-9));
      expect(canvas.backgroundColor[1], closeTo(0.25, 1e-9));
      expect(canvas.backgroundColor[2], closeTo(0.75, 1e-9));
      expect(canvas.backgroundColor[3], closeTo(0.8, 1e-9));
    });

    test('CD-15 fromMap() with integer width/height (num coercion)', () {
      // MethodChannel may deliver ints for numeric fields.
      final m = <Object?, Object?>{
        'width': 720,
        'height': 1280,
        'contentMode': 'fill',
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.width, 720);
      expect(canvas.height, 1280);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // fromMap() invalid/missing width and height → defaults
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — fromMap() width/height fallback', () {
    test('CD-16 missing width falls back to 1080', () {
      final m = <Object?, Object?>{
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.width, 1080);
    });

    test('CD-17 missing height falls back to 1920', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'contentMode': 'fit',
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.height, 1920);
    });

    test('CD-18 zero/negative width and height fall back to defaults', () {
      final m = <Object?, Object?>{
        'width': 0,
        'height': -1,
        'contentMode': 'fit',
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.width, 1080);
      expect(canvas.height, 1920);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // fromMap() negative safe-area values → clamped to 0
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — fromMap() negative safe-area clamping', () {
    test('CD-19 negative safeAreaTop is clamped to 0', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
        'safeAreaTop': -10.0,
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.safeAreaTop, 0.0);
    });

    test('CD-20 negative safeAreaBottom is clamped to 0', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
        'safeAreaBottom': -5.0,
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.safeAreaBottom, 0.0);
    });

    test('CD-21 all negative safe-area values clamp to 0', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
        'safeAreaTop': -1.0,
        'safeAreaBottom': -2.0,
        'safeAreaLeft': -3.0,
        'safeAreaRight': -4.0,
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.safeAreaTop, 0.0);
      expect(canvas.safeAreaBottom, 0.0);
      expect(canvas.safeAreaLeft, 0.0);
      expect(canvas.safeAreaRight, 0.0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // fromMap() invalid/missing backgroundColor → default [0,0,0,1]
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — fromMap() backgroundColor fallback', () {
    test('CD-22 missing backgroundColor uses default [0,0,0,1]', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.backgroundColor, [0.0, 0.0, 0.0, 1.0]);
    });

    test('CD-23 malformed backgroundColor (not a list) uses default', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': 'red', // invalid — not a list
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.backgroundColor, [0.0, 0.0, 0.0, 1.0]);
    });

    test('CD-24 backgroundColor with wrong number of elements uses default', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [1.0, 0.0, 0.0], // only 3 elements
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.backgroundColor, [0.0, 0.0, 0.0, 1.0]);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // fromMap() out-of-range backgroundColor → clamped to [0.0, 1.0]
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — fromMap() backgroundColor clamping', () {
    test('CD-25 backgroundColor components above 1.0 are clamped to 1.0', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [2.0, 1.5, 1.0, 1.0],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.backgroundColor[0], closeTo(1.0, 1e-9));
      expect(canvas.backgroundColor[1], closeTo(1.0, 1e-9));
      expect(canvas.backgroundColor[2], closeTo(1.0, 1e-9));
    });

    test('CD-26 backgroundColor components below 0.0 are clamped to 0.0', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [-0.5, -1.0, 0.5, 1.0],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.backgroundColor[0], closeTo(0.0, 1e-9));
      expect(canvas.backgroundColor[1], closeTo(0.0, 1e-9));
      expect(canvas.backgroundColor[2], closeTo(0.5, 1e-9));
    });

    test('CD-27 mixed out-of-range and valid components are individually clamped', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [-1.0, 0.5, 2.0, 0.8],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.backgroundColor[0], closeTo(0.0, 1e-9));
      expect(canvas.backgroundColor[1], closeTo(0.5, 1e-9));
      expect(canvas.backgroundColor[2], closeTo(1.0, 1e-9));
      expect(canvas.backgroundColor[3], closeTo(0.8, 1e-9));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // fromMap() unknown contentMode → fit
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — fromMap() contentMode fallback', () {
    test('CD-28 unknown contentMode string falls back to fit', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 'panorama', // unknown
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.contentMode, VGCanvasContentMode.fit);
    });

    test('CD-29 missing contentMode key falls back to fit', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.contentMode, VGCanvasContentMode.fit);
    });

    test('CD-30 non-string contentMode value falls back to fit', () {
      final m = <Object?, Object?>{
        'width': 1080,
        'height': 1920,
        'contentMode': 42, // wrong type
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
      };
      final canvas = VGCanvasDescriptor.fromMap(m);
      expect(canvas, isNotNull);
      expect(canvas!.contentMode, VGCanvasContentMode.fit);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // All contentMode enum values serialize and deserialize correctly
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasContentMode — enum round-trip', () {
    test('CD-31 VGCanvasContentMode.fit serializes to "fit" and back', () {
      expect(VGCanvasContentMode.fit.value, 'fit');
      expect(VGCanvasContentMode.fromValue('fit'), VGCanvasContentMode.fit);

      final m = <Object?, Object?>{
        'width': 1080, 'height': 1920,
        'contentMode': 'fit',
        'backgroundColor': [0.0, 0.0, 0.0, 1.0],
      };
      expect(VGCanvasDescriptor.fromMap(m)!.contentMode, VGCanvasContentMode.fit);
    });

    test('CD-32 VGCanvasContentMode.fill serializes to "fill" and back', () {
      expect(VGCanvasContentMode.fill.value, 'fill');
      expect(VGCanvasContentMode.fromValue('fill'), VGCanvasContentMode.fill);

      final canvas = VGCanvasDescriptor(contentMode: VGCanvasContentMode.fill);
      final clone = VGCanvasDescriptor.fromMap(
        Map<Object?, Object?>.from(canvas.toMap()),
      );
      expect(clone!.contentMode, VGCanvasContentMode.fill);
    });

    test('CD-33 VGCanvasContentMode.stretch serializes to "stretch" and back', () {
      expect(VGCanvasContentMode.stretch.value, 'stretch');
      expect(VGCanvasContentMode.fromValue('stretch'), VGCanvasContentMode.stretch);

      final canvas = VGCanvasDescriptor(contentMode: VGCanvasContentMode.stretch);
      final clone = VGCanvasDescriptor.fromMap(
        Map<Object?, Object?>.from(canvas.toMap()),
      );
      expect(clone!.contentMode, VGCanvasContentMode.stretch);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // copyWith
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — copyWith', () {
    test('CD-34 copyWith preserves unchanged fields', () {
      final original = VGCanvasDescriptor(
        width: 1080,
        height: 1920,
        contentMode: VGCanvasContentMode.fill,
        backgroundColor: [0.1, 0.2, 0.3, 1.0],
        safeAreaTop: 44.0,
      );
      final copy = original.copyWith(width: 720);
      expect(copy.width, 720);
      expect(copy.height, 1920);
      expect(copy.contentMode, VGCanvasContentMode.fill);
      expect(copy.backgroundColor, [0.1, 0.2, 0.3, 1.0]);
      expect(copy.safeAreaTop, 44.0);
    });

    test('CD-35 copyWith can change contentMode', () {
      final original = VGCanvasDescriptor();
      final copy = original.copyWith(contentMode: VGCanvasContentMode.fill);
      expect(copy.contentMode, VGCanvasContentMode.fill);
    });

    test('CD-36 copyWith can change all safe-area insets', () {
      final original = VGCanvasDescriptor();
      final copy = original.copyWith(
        safeAreaTop: 44.0,
        safeAreaBottom: 34.0,
        safeAreaLeft: 8.0,
        safeAreaRight: 8.0,
      );
      expect(copy.safeAreaTop, 44.0);
      expect(copy.safeAreaBottom, 34.0);
      expect(copy.safeAreaLeft, 8.0);
      expect(copy.safeAreaRight, 8.0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Equality and hashCode
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — equality and hashCode', () {
    test('CD-37 identical descriptors are equal', () {
      final a = VGCanvasDescriptor();
      final b = VGCanvasDescriptor();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('CD-38 descriptors with different widths are not equal', () {
      final a = VGCanvasDescriptor(width: 1080);
      final b = VGCanvasDescriptor(width: 720);
      expect(a == b, isFalse);
    });

    test('CD-39 descriptors with different contentModes are not equal', () {
      final a = VGCanvasDescriptor(contentMode: VGCanvasContentMode.fit);
      final b = VGCanvasDescriptor(contentMode: VGCanvasContentMode.fill);
      expect(a == b, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Null input
  // ───────────────────────────────────────────────────────────────────────────

  group('VGCanvasDescriptor — null input', () {
    test('CD-40 fromMap(null) returns null', () {
      expect(VGCanvasDescriptor.fromMap(null), isNull);
    });
  });
}
