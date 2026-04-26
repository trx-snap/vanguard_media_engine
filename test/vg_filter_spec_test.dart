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
}

// ── AC coverage summary (P4-10) ────────────────────────────────────────────
//
// P410-01  VGFilterSpecs.lut() type and default intensity (plan:393)
// P410-02  VGFilterSpecs.beauty(intensity: 0.5) custom + default radius (plan:394)
// P410-03  VGFilterSpecs.segmentation() type and empty parameters (plan:395)
// P410-04  assertValid() passes for lut, beauty, segmentation (plan:396)
// P410-05  assertValid() throws AssertionError for unknown type (plan:397)
