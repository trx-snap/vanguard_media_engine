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
  test('VGFilterSpecs.beauty(intensity: 0.5) preserves custom intensity '
      'and default radius (plan:394)', () {
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
  });

  // ── Test 3 ────────────────────────────────────────────────────────────────
  test('VGFilterSpecs.segmentation() produces type=="segmentation" '
      'with empty parameters (plan:395)', () {
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
  });

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
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ];
      final spec = VGFilterSpecs.colorMatrix(matrix: identity);

      expect(
        spec.type,
        equals('colorMatrix'),
        reason: 'colorMatrix() must produce type string "colorMatrix"',
      );
      expect(
        spec.enabled,
        isTrue,
        reason: 'colorMatrix() default enabled must be true',
      );

      final matrix = spec.parameters['matrix'] as List<double>;
      expect(
        matrix.length,
        equals(20),
        reason: 'matrix parameter must contain exactly 20 elements',
      );
      expect(
        matrix[0],
        closeTo(1.0, 1e-9),
        reason: 'Row 0 col 0 of identity matrix must be 1.0',
      );
      expect(
        matrix[1],
        closeTo(0.0, 1e-9),
        reason: 'Row 0 col 1 of identity matrix must be 0.0',
      );
    },
  );

  // ── Test 7 ────────────────────────────────────────────────────────────────
  test('VGFilterSpecs.colorMatrix() toJson() serialises matrix correctly', () {
    final spec = VGFilterSpecs.colorMatrix(
      matrix: List<double>.filled(20, 0.5),
    );
    final json = spec.toJson();

    expect(json['type'], equals('colorMatrix'));
    expect(json['enabled'], isTrue);
    final matrix = (json['parameters'] as Map)['matrix'] as List;
    expect(matrix.length, equals(20));
    expect(matrix.first, closeTo(0.5, 1e-9));
  });

  // ── Test 8 ────────────────────────────────────────────────────────────────
  test('VGFilterSpecs.colorMatrix() assertValid() does not throw', () {
    final spec = VGFilterSpecs.colorMatrix(
      matrix: List<double>.filled(20, 0.0),
    );
    expect(
      () => spec.assertValid(),
      returnsNormally,
      reason: '"colorMatrix" is in _validTypes; assertValid() must not throw',
    );
  });

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

      expect(
        spec.type,
        equals('transform'),
        reason: 'transform() must produce type string "transform"',
      );
      expect(
        spec.enabled,
        isTrue,
        reason: 'transform() default enabled must be true',
      );
      expect(spec.parameters['canvasWidth'], equals(1080));
      expect(spec.parameters['canvasHeight'], equals(1920));
      expect((spec.parameters['scale'] as num).toDouble(), closeTo(1.5, 1e-9));
      expect(
        (spec.parameters['offsetX'] as num).toDouble(),
        closeTo(0.2, 1e-9),
      );
      expect(
        (spec.parameters['offsetY'] as num).toDouble(),
        closeTo(-0.3, 1e-9),
      );
      expect(spec.parameters['rotationQuarterTurns'], equals(1));
      expect(spec.parameters['flipX'], isTrue);
      expect(
        spec.parameters.containsKey('cropRect'),
        isFalse,
        reason: 'cropRect absent when not provided',
      );
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
  test('VGFilterSpecs.transform() assertValid() does not throw '
      '("transform" is in _validTypes)', () {
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
  });

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
      final spec4 = VGFilterSpecs.transform(
        canvasWidth: 1080,
        canvasHeight: 1920,
        scale: 1.0,
        offsetX: 0.0,
        offsetY: 0.0,
        rotationQuarterTurns: 4, // 4 mod 4 = 0
        flipX: false,
      );
      expect(
        spec4.parameters['rotationQuarterTurns'],
        equals(0),
        reason: 'quarterTurns=4 must normalise to 0',
      );

      final spec5 = VGFilterSpecs.transform(
        canvasWidth: 1080,
        canvasHeight: 1920,
        scale: 1.0,
        offsetX: 0.0,
        offsetY: 0.0,
        rotationQuarterTurns: 5, // 5 mod 4 = 1
        flipX: false,
      );
      expect(
        spec5.parameters['rotationQuarterTurns'],
        equals(1),
        reason: 'quarterTurns=5 must normalise to 1',
      );
    },
  );

  // ── Test 15 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.transform() throws AssertionError for canvasWidth <= 0',
    () {
      expect(
        () => VGFilterSpecs.transform(
          canvasWidth: 0, // invalid
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
          canvasHeight: -1, // invalid
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
  test('VGFilterSpecs.transform() throws AssertionError for scale <= 0', () {
    expect(
      () => VGFilterSpecs.transform(
        canvasWidth: 1080,
        canvasHeight: 1920,
        scale: 0.0, // invalid
        offsetX: 0.0,
        offsetY: 0.0,
        rotationQuarterTurns: 0,
        flipX: false,
      ),
      throwsA(isA<AssertionError>()),
      reason: 'scale=0.0 must throw AssertionError',
    );
  });

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
          cropRect: [0.0, 0.0, 1.0], // only 3 elements — invalid
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
          cropRect: [0.0, 0.0, 0.0, 1.0], // w=0 — invalid
        ),
        throwsA(isA<AssertionError>()),
        reason: 'cropRect with w=0 must throw AssertionError',
      );
    },
  );

  // ── Phase 3 greenScreen alpha-output contract ──────────────────────────────

  // ── Test 20 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreenAlpha() serialises type=="greenScreen" with '
      'parameters exactly {backgroundType: alpha} and no argb', () {
    final spec = VGFilterSpecs.greenScreenAlpha();

    expect(
      spec.type,
      equals('greenScreen'),
      reason: 'greenScreenAlpha() must produce type string "greenScreen"',
    );
    expect(
      spec.enabled,
      isTrue,
      reason: 'greenScreenAlpha() default enabled must be true',
    );
    expect(
      spec.parameters,
      equals(<String, Object?>{'backgroundType': 'alpha'}),
      reason: 'alpha parameters must be exactly {backgroundType: alpha}',
    );
    expect(
      spec.parameters.containsKey('argb'),
      isFalse,
      reason: 'argb is not part of the alpha contract and must be absent',
    );

    final json = spec.toJson();
    expect(
      json,
      equals(<String, Object?>{
        'type': 'greenScreen',
        'enabled': true,
        'parameters': <String, Object?>{'backgroundType': 'alpha'},
      }),
      reason: 'toJson() must emit the documented alpha wire format',
    );
  });

  // ── Test 21 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreenAlpha() assertValid() does not throw and the '
      'spec differs from greenScreenSolidColor()', () {
    expect(
      () => VGFilterSpecs.greenScreenAlpha().assertValid(),
      returnsNormally,
      reason: '"greenScreen" is a known type; assertValid() must not throw',
    );
    expect(
      VGFilterSpecs.greenScreenAlpha(),
      isNot(equals(VGFilterSpecs.greenScreenSolidColor())),
      reason: 'alpha and solidColor specs must not compare equal',
    );
    expect(
      VGFilterSpecs.greenScreenAlpha(),
      equals(VGFilterSpecs.greenScreenAlpha()),
      reason: 'greenScreenAlpha() must be deterministic (value equality)',
    );
  });

  // ── Test 22 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreenSolidColor() default wire format is preserved '
      '(backgroundType solidColor, argb 0xFF00796B, nothing else)', () {
    final spec = VGFilterSpecs.greenScreenSolidColor();

    expect(spec.type, equals('greenScreen'));
    expect(spec.enabled, isTrue);
    expect(
      spec.parameters,
      equals(<String, Object?>{
        'backgroundType': 'solidColor',
        'argb': 0xFF00796B,
      }),
      reason: 'solidColor default parameters must be unchanged',
    );

    final json = spec.toJson();
    expect(
      json,
      equals(<String, Object?>{
        'type': 'greenScreen',
        'enabled': true,
        'parameters': <String, Object?>{
          'backgroundType': 'solidColor',
          'argb': 0xFF00796B,
        },
      }),
      reason: 'toJson() must emit the documented solidColor wire format',
    );
  });

  // ── Test 23 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreenSolidColor(argb: ...) forwards a custom argb '
      'and passes assertValid()', () {
    final spec = VGFilterSpecs.greenScreenSolidColor(argb: 0x80123456);

    expect(spec.parameters['backgroundType'], equals('solidColor'));
    expect(spec.parameters['argb'], equals(0x80123456));
    expect(
      () => spec.assertValid(),
      returnsNormally,
      reason: '"greenScreen" is a known type; assertValid() must not throw',
    );
  });

  // ── Test 24 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreenSolidColor() throws AssertionError for argb '
      'outside [0, 0xFFFFFFFF]', () {
    expect(
      () => VGFilterSpecs.greenScreenSolidColor(argb: -1),
      throwsA(isA<AssertionError>()),
      reason: 'argb=-1 must throw AssertionError',
    );
    expect(
      () => VGFilterSpecs.greenScreenSolidColor(argb: 0x100000000),
      throwsA(isA<AssertionError>()),
      reason: 'argb=0x100000000 must throw AssertionError',
    );
  });

  // ── Vanguard Unified Camera Green Screen Contract §3 (Package A) ───────────
  // packages/UMF/Docs/Vanguard_Unified_Camera_GreenScreen_Contract.md
  // Canonical VGFilterSpecs.greenScreen() factory: flat backgroundType/
  // scaleMode/argb/imagePath/scale/offsetX/offsetY keys, no nested transform
  // map. Distinct from (and does not replace) greenScreenSolidColor /
  // greenScreenAlpha above, which remain unchanged.

  // ── Test 25 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreen(backgroundType: solidColor) serialises exact '
      'canonical flat keys with no imagePath', () {
    final spec = VGFilterSpecs.greenScreen(
      backgroundType: 'solidColor',
      argb: 0xFF1B5E20,
    );

    expect(spec.type, equals('greenScreen'));
    expect(spec.enabled, isTrue);
    expect(
      spec.parameters,
      equals(<String, Object?>{
        'backgroundType': 'solidColor',
        'scaleMode': 'aspectFill',
        'argb': 0xFF1B5E20,
        'scale': 1.0,
        'offsetX': 0.0,
        'offsetY': 0.0,
      }),
      reason:
          'solidColor parameters must be exactly these flat keys — '
          'no imagePath, no nested transform map',
    );
    expect(spec.parameters.containsKey('imagePath'), isFalse);
  });

  // ── Test 26 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreen(backgroundType: imageFile) serialises exact '
      'canonical flat keys with no argb', () {
    final spec = VGFilterSpecs.greenScreen(
      backgroundType: 'imageFile',
      imagePath: '/data/user/0/com.connects/files/bg.jpg',
      scaleMode: 'aspectFit',
      scale: 1.5,
      offsetX: 0.2,
      offsetY: -0.3,
    );

    expect(spec.type, equals('greenScreen'));
    expect(
      spec.parameters,
      equals(<String, Object?>{
        'backgroundType': 'imageFile',
        'scaleMode': 'aspectFit',
        'imagePath': '/data/user/0/com.connects/files/bg.jpg',
        'scale': 1.5,
        'offsetX': 0.2,
        'offsetY': -0.3,
      }),
      reason:
          'imageFile parameters must be exactly these flat keys — '
          'no argb, no nested transform map',
    );
    expect(spec.parameters.containsKey('argb'), isFalse);
  });

  // ── Test 27 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreen() toJson() emits the exact canonical '
      'wire format for solidColor', () {
    final spec = VGFilterSpecs.greenScreen(
      backgroundType: 'solidColor',
      argb: 0xFF00796B,
    );
    final json = spec.toJson();

    expect(
      json,
      equals(<String, Object?>{
        'type': 'greenScreen',
        'enabled': true,
        'parameters': <String, Object?>{
          'backgroundType': 'solidColor',
          'scaleMode': 'aspectFill',
          'argb': 0xFF00796B,
          'scale': 1.0,
          'offsetX': 0.0,
          'offsetY': 0.0,
        },
      }),
    );
  });

  // ── Test 28 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.greenScreen() assertValid() does not throw ("greenScreen" '
    'is in _validTypes)',
    () {
      expect(
        () => VGFilterSpecs.greenScreen(
          backgroundType: 'solidColor',
          argb: 0xFF000000,
        ).assertValid(),
        returnsNormally,
      );
    },
  );

  // ── Test 29 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.greenScreen() throws AssertionError for backgroundType == '
    '"image" (not the canonical "imageFile")',
    () {
      expect(
        () => VGFilterSpecs.greenScreen(
          backgroundType: 'image',
          imagePath: '/tmp/bg.jpg',
        ),
        throwsA(isA<AssertionError>()),
      );
    },
  );

  // ── Test 30 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreen() throws AssertionError for scaleMode not in '
      '{aspectFill, aspectFit} (cover/contain/fit rejected)', () {
    for (final badMode in ['cover', 'contain', 'fit']) {
      expect(
        () => VGFilterSpecs.greenScreen(
          backgroundType: 'solidColor',
          argb: 0xFF000000,
          scaleMode: badMode,
        ),
        throwsA(isA<AssertionError>()),
        reason: 'scaleMode "$badMode" must not be accepted',
      );
    }
  });

  // ── Test 31 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.greenScreen() throws AssertionError when backgroundType == '
    '"solidColor" and argb is omitted',
    () {
      expect(
        () => VGFilterSpecs.greenScreen(backgroundType: 'solidColor'),
        throwsA(isA<AssertionError>()),
      );
    },
  );

  // ── Test 32 ───────────────────────────────────────────────────────────────
  test(
    'VGFilterSpecs.greenScreen() throws AssertionError when backgroundType == '
    '"imageFile" and imagePath is omitted, blank, or whitespace-only',
    () {
      expect(
        () => VGFilterSpecs.greenScreen(backgroundType: 'imageFile'),
        throwsA(isA<AssertionError>()),
        reason: 'missing imagePath must throw',
      );
      expect(
        () => VGFilterSpecs.greenScreen(
          backgroundType: 'imageFile',
          imagePath: '',
        ),
        throwsA(isA<AssertionError>()),
        reason: 'blank imagePath must throw',
      );
      expect(
        () => VGFilterSpecs.greenScreen(
          backgroundType: 'imageFile',
          imagePath: '   ',
        ),
        throwsA(isA<AssertionError>()),
        reason: 'whitespace-only imagePath must throw',
      );
    },
  );

  // ── Test 33 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreen() throws AssertionError for a relative '
      '(non-absolute) imagePath', () {
    expect(
      () => VGFilterSpecs.greenScreen(
        backgroundType: 'imageFile',
        imagePath: 'relative/bg.jpg',
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  // ── Test 34 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreen() clamps scale/offsetX/offsetY to the '
      'canonical ranges', () {
    final aboveMax = VGFilterSpecs.greenScreen(
      backgroundType: 'solidColor',
      argb: 0xFF000000,
      scale: 5.0,
      offsetX: 2.0,
      offsetY: -2.0,
    );
    expect(
      (aboveMax.parameters['scale'] as num).toDouble(),
      closeTo(3.0, 1e-9),
    );
    expect(
      (aboveMax.parameters['offsetX'] as num).toDouble(),
      closeTo(1.0, 1e-9),
    );
    expect(
      (aboveMax.parameters['offsetY'] as num).toDouble(),
      closeTo(-1.0, 1e-9),
    );

    final belowMin = VGFilterSpecs.greenScreen(
      backgroundType: 'solidColor',
      argb: 0xFF000000,
      scale: 0.0,
      offsetX: -5.0,
      offsetY: 5.0,
    );
    expect(
      (belowMin.parameters['scale'] as num).toDouble(),
      closeTo(0.25, 1e-9),
    );
    expect(
      (belowMin.parameters['offsetX'] as num).toDouble(),
      closeTo(-1.0, 1e-9),
    );
    expect(
      (belowMin.parameters['offsetY'] as num).toDouble(),
      closeTo(1.0, 1e-9),
    );
  });

  // ── Test 35 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreen() defaults scaleMode to aspectFill and '
      'transform to identity (scale 1.0, offsets 0.0)', () {
    final spec = VGFilterSpecs.greenScreen(
      backgroundType: 'solidColor',
      argb: 0xFF000000,
    );
    expect(spec.parameters['scaleMode'], equals('aspectFill'));
    expect((spec.parameters['scale'] as num).toDouble(), closeTo(1.0, 1e-9));
    expect((spec.parameters['offsetX'] as num).toDouble(), closeTo(0.0, 1e-9));
    expect((spec.parameters['offsetY'] as num).toDouble(), closeTo(0.0, 1e-9));
  });

  // ── Test 36 ───────────────────────────────────────────────────────────────
  test('VGFilterSpecs.greenScreen() never emits a nested "transform" map — all '
      'parameters are flat top-level scalars', () {
    final spec = VGFilterSpecs.greenScreen(
      backgroundType: 'imageFile',
      imagePath: '/tmp/bg.jpg',
      scale: 1.2,
      offsetX: 0.1,
      offsetY: 0.1,
    );
    expect(
      spec.parameters.containsKey('transform'),
      isFalse,
      reason: 'the canonical contract forbids a nested transform map',
    );
    for (final value in spec.parameters.values) {
      expect(
        value is Map,
        isFalse,
        reason:
            'every canonical greenScreen parameter must be a flat '
            'scalar (String/int/double), never a nested Map',
      );
    }
  });

  // ── Test 37 ───────────────────────────────────────────────────────────────
  test('greenScreenSolidColor() and greenScreenAlpha() remain unchanged '
      'alongside the new canonical greenScreen() factory', () {
    // Same exact wire shape as before this Package A addition (Tests 20-24).
    final solid = VGFilterSpecs.greenScreenSolidColor();
    expect(
      solid.parameters,
      equals(<String, Object?>{
        'backgroundType': 'solidColor',
        'argb': 0xFF00796B,
      }),
    );
    final alpha = VGFilterSpecs.greenScreenAlpha();
    expect(
      alpha.parameters,
      equals(<String, Object?>{'backgroundType': 'alpha'}),
    );

    // The new canonical factory produces a materially different shape
    // (scaleMode/scale/offsetX/offsetY are never part of the legacy pair).
    final canonical = VGFilterSpecs.greenScreen(
      backgroundType: 'solidColor',
      argb: 0xFF00796B,
    );
    expect(canonical.parameters.containsKey('scaleMode'), isTrue);
    expect(solid.parameters.containsKey('scaleMode'), isFalse);
  });
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
// GS-ALPHA-01  greenScreenAlpha() type, exact parameters, no argb, toJson (Test 20)
// GS-ALPHA-02  greenScreenAlpha() assertValid passes; differs from solidColor (Test 21)
// GS-ALPHA-03  greenScreenSolidColor() default wire format preserved (Test 22)
// GS-ALPHA-04  greenScreenSolidColor(argb:) forwards argb, assertValid passes (Test 23)
// GS-ALPHA-05  greenScreenSolidColor() asserts on out-of-range argb (Test 24)
//
// ── Package A: Vanguard Unified Camera Green Screen Contract §3 ─────────────
// GS-CANON-01  greenScreen() solidColor exact flat keys, no imagePath (Test 25)
// GS-CANON-02  greenScreen() imageFile exact flat keys, no argb (Test 26)
// GS-CANON-03  greenScreen() toJson() exact canonical wire format (Test 27)
// GS-CANON-04  greenScreen() assertValid() passes (Test 28)
// GS-CANON-05  greenScreen() asserts on backgroundType == "image" (Test 29)
// GS-CANON-06  greenScreen() asserts on scaleMode cover/contain/fit (Test 30)
// GS-CANON-07  greenScreen() asserts solidColor without argb (Test 31)
// GS-CANON-08  greenScreen() asserts imageFile without/blank imagePath (Test 32)
// GS-CANON-09  greenScreen() asserts relative (non-absolute) imagePath (Test 33)
// GS-CANON-10  greenScreen() clamps scale/offsetX/offsetY to range (Test 34)
// GS-CANON-11  greenScreen() defaults: aspectFill, identity transform (Test 35)
// GS-CANON-12  greenScreen() never emits a nested transform map (Test 36)
// GS-CANON-13  legacy greenScreenSolidColor/greenScreenAlpha unchanged (Test 37)
