// vg_filter_spec_test.dart
// Vanguard Media Engine — Phase 4, P4-10
//
// Gate tests for the VGFilterSpecs typed constructors and assertValid() method.
// Validates RR-34 closure: typed factory constructors enforce correct type strings
// and parameters; assertValid() catches unrecognised types in debug mode.
//
// Acceptance criteria (plan:393–397):
//   1. VGFilterSpecs.lut()          → type == 'lut',  intensity == 1.0
//   2. VGFilterSpecs.beauty(intensity: 0.5) → type == 'beauty', intensity == 0.5,
//                                             radius default preserved
//   3. VGFilterSpecs.segmentation() → type == 'segmentation', parameters empty
//   4. assertValid() passes for known types (no throw)
//   5. assertValid() fails for unknown type with AssertionError

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_filter_spec.dart';

void main() {
  // P4-10 gate: 5 required tests (plan:393–397, RR-34 closure)

  // ── Test 1 ────────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.lut() produces type=="lut" and intensity==1.0 (plan:393)',
    () {
      final spec = VGFilterSpecs.lut();

      expect(
        spec.type,
        equals('lut'),
        reason: 'lut() must produce type string "lut"',
      );
      expect(
        spec.parameters['intensity'],
        closeTo(1.0, 1e-9),
        reason: 'lut() default intensity must be 1.0',
      );
      expect(
        spec.enabled,
        isTrue,
        reason: 'lut() default enabled must be true',
      );
    },
  );

  // ── Test 2 ────────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.beauty(intensity: 0.5) preserves custom intensity '
    'and default radius (plan:394)',
    () {
      final spec = VGFilterSpecs.beauty(intensity: 0.5);

      expect(
        spec.type,
        equals('beauty'),
        reason: 'beauty() must produce type string "beauty"',
      );
      expect(
        spec.parameters['intensity'],
        closeTo(0.5, 1e-9),
        reason: 'Custom intensity must be forwarded to parameters',
      );
      expect(
        spec.parameters.containsKey('radius'),
        isTrue,
        reason: 'beauty() must include radius key even when using default',
      );
      expect(
        spec.parameters['radius'],
        closeTo(2.0, 1e-9),
        reason: 'Default radius must be 2.0',
      );
    },
  );

  // ── Test 3 ────────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.segmentation() produces type=="segmentation" '
    'with empty parameters (plan:395)',
    () {
      final spec = VGFilterSpecs.segmentation();

      expect(
        spec.type,
        equals('segmentation'),
        reason: 'segmentation() must produce type string "segmentation"',
      );
      expect(
        spec.parameters,
        isEmpty,
        reason: 'segmentation() must have empty parameters (no Phase 4 params)',
      );
    },
  );

  // ── Test 4 ────────────────────────────────────────────────────────────────
  test(
    'assertValid() does NOT throw for known types: lut, beauty, segmentation '
    '(plan:396)',
    () {
      // All three known types must pass assertValid() without throwing.
      expect(
        () => VGFilterSpecs.lut().assertValid(),
        returnsNormally,
        reason: '"lut" is a known type; assertValid() must not throw',
      );
      expect(
        () => VGFilterSpecs.beauty().assertValid(),
        returnsNormally,
        reason: '"beauty" is a known type; assertValid() must not throw',
      );
      expect(
        () => VGFilterSpecs.segmentation().assertValid(),
        returnsNormally,
        reason: '"segmentation" is a known type; assertValid() must not throw',
      );
    },
  );

  // ── Test 5 ────────────────────────────────────────────────────────────────
  test(
    'assertValid() throws AssertionError for an unknown filter type (plan:397)',
    () {
      const unknownSpec = VGFilterSpec(type: 'invalid_filter_xyz');

      // assertValid() uses Dart's `assert` — active in debug/test mode.
      // The assert throws AssertionError, which is a subtype of Error.
      expect(
        () => unknownSpec.assertValid(),
        throwsA(isA<AssertionError>()),
        reason:
            'assertValid() must throw AssertionError for unrecognised type '
            '"invalid_filter_xyz" (not in _validTypes allowlist)',
      );
    },
  );

  // ── Phase 10-C-3L.1C: colorMatrix factory tests ────────────────────────────

  // ── Test 6 ────────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.colorMatrix() produces correct type and matrix parameter',
    () {
      // Identity matrix: no-op color transform.
      final identity = <double>[
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0,
      ];
      final spec = VGFilterSpecs.colorMatrix(matrix: identity);

      expect(spec.type, equals('colorMatrix'),
          reason: 'colorMatrix() must produce type string "colorMatrix"');
      expect(spec.enabled, isTrue,
          reason: 'colorMatrix() default enabled must be true');

      final matrix = spec.parameters['matrix'] as List<double>;
      expect(matrix.length, equals(20),
          reason: 'matrix parameter must contain exactly 20 elements');
      expect(matrix[0], closeTo(1.0, 1e-9),
          reason: 'Row 0 col 0 of identity matrix must be 1.0');
      expect(matrix[1], closeTo(0.0, 1e-9),
          reason: 'Row 0 col 1 of identity matrix must be 0.0');
    },
  );

  // ── Test 7 ────────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.colorMatrix() toJson() serialises matrix correctly',
    () {
      final spec = VGFilterSpecs.colorMatrix(matrix: List<double>.filled(20, 0.5));
      final json = spec.toJson();

      expect(json['type'], equals('colorMatrix'));
      expect(json['enabled'], isTrue);
      final matrix = (json['parameters'] as Map)['matrix'] as List;
      expect(matrix.length, equals(20));
      expect(matrix.first, closeTo(0.5, 1e-9));
    },
  );

  // ── Test 8 ────────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.colorMatrix() assertValid() does not throw',
    () {
      final spec = VGFilterSpecs.colorMatrix(matrix: List<double>.filled(20, 0.0));
      expect(
        () => spec.assertValid(),
        returnsNormally,
        reason: '"colorMatrix" is in _validTypes; assertValid() must not throw',
      );
    },
  );

  // ── Test 9 ────────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.colorMatrix() throws AssertionError for wrong-length matrix',
    () {
      // Only fires in debug/test mode where Dart asserts are enabled.
      expect(
        () => VGFilterSpecs.colorMatrix(matrix: List<double>.filled(19, 0.0)),
        throwsA(isA<AssertionError>()),
        reason: 'colorMatrix() must assert exactly 20 elements',
      );
    },
  );

  // ── Phase 10-C-3L.1D: transform factory tests ──────────────────────────────

  // ── Test 10 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() produces correct type and all required parameters',
    () {
      final spec = VGFilterSpecs.transform(
        canvasWidth: 1080,
        canvasHeight: 1920,
        scale: 1.5,
        offsetX: 0.2,
        offsetY: -0.3,
        rotationQuarterTurns: 1,
        flipX: true,
      );

      expect(spec.type, equals('transform'),
          reason: 'transform() must produce type string "transform"');
      expect(spec.enabled, isTrue,
          reason: 'transform() default enabled must be true');
      expect(spec.parameters['canvasWidth'], equals(1080));
      expect(spec.parameters['canvasHeight'], equals(1920));
      expect((spec.parameters['scale'] as num).toDouble(), closeTo(1.5, 1e-9));
      expect((spec.parameters['offsetX'] as num).toDouble(), closeTo(0.2, 1e-9));
      expect((spec.parameters['offsetY'] as num).toDouble(), closeTo(-0.3, 1e-9));
      expect(spec.parameters['rotationQuarterTurns'], equals(1));
      expect(spec.parameters['flipX'], isTrue);
      expect(spec.parameters.containsKey('cropRect'), isFalse,
          reason: 'cropRect absent when not provided');
    },
  );

  // ── Test 11 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() toJson() serialises all fields correctly',
    () {
      final spec = VGFilterSpecs.transform(
        canvasWidth: 720,
        canvasHeight: 1280,
        scale: 2.0,
        offsetX: 0.0,
        offsetY: 0.0,
        rotationQuarterTurns: 0,
        flipX: false,
        cropRect: [0.1, 0.15, 0.8, 0.7],
      );
      final json = spec.toJson();

      expect(json['type'], equals('transform'));
      expect(json['enabled'], isTrue);
      final params = json['parameters'] as Map;
      expect(params['canvasWidth'], equals(720));
      expect(params['canvasHeight'], equals(1280));
      expect((params['scale'] as num).toDouble(), closeTo(2.0, 1e-9));
      expect(params['flipX'], isFalse);
      final cropRect = params['cropRect'] as List;
      expect(cropRect.length, equals(4));
      expect((cropRect[0] as num).toDouble(), closeTo(0.1, 1e-9));
      expect((cropRect[2] as num).toDouble(), closeTo(0.8, 1e-9));
    },
  );

  // ── Test 12 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() assertValid() does not throw '
    '("transform" is in _validTypes)',
    () {
      final spec = VGFilterSpecs.transform(
        canvasWidth: 1080,
        canvasHeight: 1920,
        scale: 1.0,
        offsetX: 0.0,
        offsetY: 0.0,
        rotationQuarterTurns: 0,
        flipX: false,
      );
      expect(
        () => spec.assertValid(),
        returnsNormally,
        reason: '"transform" is a known type; assertValid() must not throw',
      );
    },
  );

  // ── Test 13 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() with cropRect serialises a 4-element list',
    () {
      final spec = VGFilterSpecs.transform(
        canvasWidth: 1080,
        canvasHeight: 1920,
        scale: 1.0,
        offsetX: 0.0,
        offsetY: 0.0,
        rotationQuarterTurns: 0,
        flipX: false,
        cropRect: [0.0, 0.0, 1.0, 1.0],
      );
      final cropRect = spec.parameters['cropRect'] as List<double>;
      expect(cropRect.length, equals(4));
      expect(cropRect[0], closeTo(0.0, 1e-9));
      expect(cropRect[2], closeTo(1.0, 1e-9));
    },
  );

  // ── Test 14 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() normalises rotationQuarterTurns to [0, 3]',
    () {
      final spec4  = VGFilterSpecs.transform(
        canvasWidth: 1080, canvasHeight: 1920,
        scale: 1.0, offsetX: 0.0, offsetY: 0.0,
        rotationQuarterTurns: 4,  // 4 mod 4 = 0
        flipX: false,
      );
      expect(spec4.parameters['rotationQuarterTurns'], equals(0),
          reason: 'quarterTurns=4 must normalise to 0');

      final spec5 = VGFilterSpecs.transform(
        canvasWidth: 1080, canvasHeight: 1920,
        scale: 1.0, offsetX: 0.0, offsetY: 0.0,
        rotationQuarterTurns: 5,  // 5 mod 4 = 1
        flipX: false,
      );
      expect(spec5.parameters['rotationQuarterTurns'], equals(1),
          reason: 'quarterTurns=5 must normalise to 1');
    },
  );

  // ── Test 15 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() throws AssertionError for canvasWidth <= 0',
    () {
      expect(
        () => VGFilterSpecs.transform(
          canvasWidth: 0,   // invalid
          canvasHeight: 1920,
          scale: 1.0,
          offsetX: 0.0,
          offsetY: 0.0,
          rotationQuarterTurns: 0,
          flipX: false,
        ),
        throwsA(isA<AssertionError>()),
        reason: 'canvasWidth=0 must throw AssertionError',
      );
    },
  );

  // ── Test 16 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() throws AssertionError for canvasHeight <= 0',
    () {
      expect(
        () => VGFilterSpecs.transform(
          canvasWidth: 1080,
          canvasHeight: -1,   // invalid
          scale: 1.0,
          offsetX: 0.0,
          offsetY: 0.0,
          rotationQuarterTurns: 0,
          flipX: false,
        ),
        throwsA(isA<AssertionError>()),
        reason: 'canvasHeight=-1 must throw AssertionError',
      );
    },
  );

  // ── Test 17 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() throws AssertionError for scale <= 0',
    () {
      expect(
        () => VGFilterSpecs.transform(
          canvasWidth: 1080,
          canvasHeight: 1920,
          scale: 0.0,   // invalid
          offsetX: 0.0,
          offsetY: 0.0,
          rotationQuarterTurns: 0,
          flipX: false,
        ),
        throwsA(isA<AssertionError>()),
        reason: 'scale=0.0 must throw AssertionError',
      );
    },
  );

  // ── Test 18 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() throws AssertionError for cropRect with wrong length',
    () {
      expect(
        () => VGFilterSpecs.transform(
          canvasWidth: 1080,
          canvasHeight: 1920,
          scale: 1.0,
          offsetX: 0.0,
          offsetY: 0.0,
          rotationQuarterTurns: 0,
          flipX: false,
          cropRect: [0.0, 0.0, 1.0],   // only 3 elements — invalid
        ),
        throwsA(isA<AssertionError>()),
        reason: 'cropRect with 3 elements must throw AssertionError',
      );
    },
  );

  // ── Test 19 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() throws AssertionError for cropRect with w=0',
    () {
      expect(
        () => VGFilterSpecs.transform(
          canvasWidth: 1080,
          canvasHeight: 1920,
          scale: 1.0,
          offsetX: 0.0,
          offsetY: 0.0,
          rotationQuarterTurns: 0,
          flipX: false,
          cropRect: [0.0, 0.0, 0.0, 1.0],   // w=0 — invalid
        ),
        throwsA(isA<AssertionError>()),
        reason: 'cropRect with w=0 must throw AssertionError',
      );
    },
  );
}

// ── AC coverage summary (P4-10 + Phase 10-C-3L.1C) ───────────────────────────
//
// P410-01  VGFilterSpecs.lut() type and default intensity (plan:393)
// P410-02  VGFilterSpecs.beauty(intensity: 0.5) custom + default radius (plan:394)
// P410-03  VGFilterSpecs.segmentation() type and empty parameters (plan:395)
// P410-04  assertValid() passes for lut, beauty, segmentation (plan:396)
// P410-05  assertValid() throws AssertionError for unknown type (plan:397)
// P10C3L1C-01  colorMatrix() produces correct type and matrix (Test 6)
// P10C3L1C-02  colorMatrix() toJson() serialises matrix (Test 7)
// P10C3L1C-03  colorMatrix() assertValid() passes (Test 8)
// P10C3L1C-04  colorMatrix() asserts on wrong-length matrix (Test 9)
// P10C3L1D-01  transform() produces correct type and parameters (Test 10)
// P10C3L1D-02  transform() toJson() serialises all fields (Test 11)
// P10C3L1D-03  transform() assertValid() passes (Test 12)
// P10C3L1D-04  transform() with cropRect serialises 4-element list (Test 13)
// P10C3L1D-05  transform() rotationQuarterTurns normalised to [0,3] (Test 14)
// P10C3L1D-06  transform() invalid canvasWidth asserts (Test 15)
// P10C3L1D-07  transform() invalid canvasHeight asserts (Test 16)
// P10C3L1D-08  transform() invalid scale asserts (Test 17)
// P10C3L1D-09  transform() cropRect wrong length asserts (Test 18)
// P10C3L1D-10  transform() cropRect invalid values asserts (Test 19)
// P10C3L1D-11  'transform' accepted by assertValid (part of Test 12)
