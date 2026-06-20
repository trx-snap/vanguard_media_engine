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
