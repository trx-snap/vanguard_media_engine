// vg_graph_transaction_test.dart
// Vanguard Media Engine — Phase 6C.1B
//
// Pure Dart unit tests for VGGraphTransaction and VGGraphTransactionPayload.
// No Flutter engine or native code required — runs in `flutter test`.
// Pattern mirrors vg_descriptor_test.dart.
//
// Acceptance criteria covered:
//   GT-1   empty transaction: isEmpty true, all flags false
//   GT-2   empty commit produces empty payload
//   GT-3   commit clears builder state
//   GT-4   set hot parameter → hasHotParameters
//   GT-5   set warm parameter → hasWarmParameters
//   GT-6   set prepare parameter → requiresRebuild
//   GT-7   applyPreset → requiresRebuild (no parameter needed)
//   GT-8   combined policy updates accumulate flags
//   GT-9   unknown effect → ArgumentError immediately
//   GT-10  unknown parameter → ArgumentError immediately
//   GT-11  invalid type → ArgumentError immediately (clamp)
//   GT-12  double/int values clamp through transaction
//   GT-13  last-write-wins for same effect/parameter
//   GT-14  preset and parameter updates coexist in payload
//   GT-15  payload parameterUpdates is deeply unmodifiable
//   GT-16  toJson() shape is stable and correct
//   GT-17  clear() resets pending state fully
//   GT-18  preset-only payload (no parameters)
//   GT-19  parameter-only payload (no preset)
//   GT-20  payload isEmpty reflects correct state
//   GT-21  commit on empty builder produces isEmpty payload
//   GT-22  multiple commits produce independent snapshots

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_graph_transaction.dart';
import 'package:vanguard_media_engine/vg_preset_descriptor.dart';
import 'package:vanguard_media_engine/vg_filter_spec.dart';
import 'package:vanguard_media_engine/vg_effect_catalog.dart';
import 'package:vanguard_media_engine/vg_parameter_descriptor.dart';

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // Helpers
  // ───────────────────────────────────────────────────────────────────────────

  VGPresetDescriptor makePreset({String id = 'p1', String name = 'P1'}) =>
      VGPresetDescriptor(
        id: id,
        name: name,
        filterStack: [VGFilterSpecs.beauty(intensity: 0.5)],
      );

  // ───────────────────────────────────────────────────────────────────────────
  // Empty state
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransaction — empty state', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GT-1a  isEmpty is true on fresh instance', () {
      expect(tx.isEmpty, isTrue);
    });

    test('GT-1b  hasHotParameters is false on fresh instance', () {
      expect(tx.hasHotParameters, isFalse);
    });

    test('GT-1c  hasWarmParameters is false on fresh instance', () {
      expect(tx.hasWarmParameters, isFalse);
    });

    test('GT-1d  requiresRebuild is false on fresh instance', () {
      expect(tx.requiresRebuild, isFalse);
    });

    test('GT-2   empty commit produces empty payload', () {
      final payload = tx.commit();
      expect(payload.isEmpty, isTrue);
      expect(payload.parameterUpdates, isEmpty);
      expect(payload.preset, isNull);
      expect(payload.hasHotParameters, isFalse);
      expect(payload.hasWarmParameters, isFalse);
      expect(payload.requiresRebuild, isFalse);
    });

    test('GT-3a  commit clears builder so second commit is empty', () {
      tx.setParameter('beauty', 'intensity', 0.5);
      tx.commit(); // first commit
      final second = tx.commit(); // second commit — should be empty
      expect(second.isEmpty, isTrue);
    });

    test('GT-3b  builder isEmpty after commit', () {
      tx.setParameter('beauty', 'intensity', 0.5);
      tx.commit();
      expect(tx.isEmpty, isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Policy flag classification
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransaction — policy flags', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    // beauty.intensity = hot
    test('GT-4   hot parameter sets hasHotParameters on builder', () {
      tx.setParameter('beauty', 'intensity', 0.5);
      expect(tx.hasHotParameters, isTrue);
      expect(tx.hasWarmParameters, isFalse);
      expect(tx.requiresRebuild, isFalse);
    });

    // beauty.radius = warm
    test('GT-5   warm parameter sets hasWarmParameters on builder', () {
      tx.setParameter('beauty', 'radius', 2.5);
      expect(tx.hasWarmParameters, isTrue);
      expect(tx.hasHotParameters, isFalse);
      expect(tx.requiresRebuild, isFalse);
    });

    // beauty.beautyVersion = prepare
    test('GT-6   prepare parameter sets requiresRebuild on builder', () {
      tx.setParameter('beauty', 'beautyVersion', 2);
      expect(tx.requiresRebuild, isTrue);
      expect(tx.hasHotParameters, isFalse);
      expect(tx.hasWarmParameters, isFalse);
    });

    test(
      'GT-7   applyPreset alone sets requiresRebuild without any parameter',
      () {
        tx.applyPreset(makePreset());
        expect(tx.requiresRebuild, isTrue);
        expect(tx.hasHotParameters, isFalse);
        expect(tx.hasWarmParameters, isFalse);
      },
    );

    test('GT-8a  combined: hot + warm + prepare all accumulate', () {
      tx.setParameter('beauty', 'intensity', 0.5); // hot
      tx.setParameter('beauty', 'radius', 2.5); // warm
      tx.setParameter('beauty', 'beautyVersion', 2); // prepare
      expect(tx.hasHotParameters, isTrue);
      expect(tx.hasWarmParameters, isTrue);
      expect(tx.requiresRebuild, isTrue);
    });

    test('GT-8b  combined: preset + hot parameter accumulate correctly', () {
      tx.applyPreset(makePreset());
      tx.setParameter('beauty', 'intensity', 0.3);
      expect(tx.requiresRebuild, isTrue);
      expect(tx.hasHotParameters, isTrue);
    });

    test('GT-8c  policy flags are correctly frozen in payload', () {
      tx.setParameter('beauty', 'intensity', 0.5); // hot
      tx.setParameter('beauty', 'radius', 2.5); // warm
      final payload = tx.commit();
      expect(payload.hasHotParameters, isTrue);
      expect(payload.hasWarmParameters, isTrue);
      expect(payload.requiresRebuild, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Validation: fail-fast on unknown effect / parameter
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransaction — fail-fast validation', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GT-9   unknown effect throws ArgumentError immediately', () {
      expect(
        () => tx.setParameter('ghostFilter', 'intensity', 0.5),
        throwsArgumentError,
      );
    });

    test(
      'GT-9b  builder remains empty after failed setParameter (unknown effect)',
      () {
        try {
          tx.setParameter('ghostFilter', 'intensity', 0.5);
        } catch (_) {}
        expect(tx.isEmpty, isTrue);
      },
    );

    test('GT-10  unknown parameter throws ArgumentError immediately', () {
      expect(
        () => tx.setParameter('beauty', 'ghostParam', 0.5),
        throwsArgumentError,
      );
    });

    test(
      'GT-10b builder remains clean after failed setParameter (unknown param)',
      () {
        try {
          tx.setParameter('beauty', 'ghostParam', 0.5);
        } catch (_) {}
        expect(tx.isEmpty, isTrue);
      },
    );

    test('GT-11  invalid type throws ArgumentError immediately', () {
      // beauty.intensity is doubleValue — passing a String should throw.
      expect(
        () => tx.setParameter('beauty', 'intensity', 'not-a-number'),
        throwsArgumentError,
      );
    });

    test('GT-11b invalid type for bool parameter throws ArgumentError', () {
      // beauty.faceAwareEnabled is boolValue — passing 1 should throw.
      expect(
        () => tx.setParameter('beauty', 'faceAwareEnabled', 1),
        throwsArgumentError,
      );
    });

    test('GT-11c invalid type for int parameter throws ArgumentError', () {
      // beauty.beautyVersion is intValue — passing a String should throw.
      expect(
        () => tx.setParameter('beauty', 'beautyVersion', 'v2'),
        throwsArgumentError,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Clamping through transaction
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransaction — clamping', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GT-12a double above max is clamped to max', () {
      tx.setParameter('beauty', 'intensity', 1.5); // max 1.0
      final payload = tx.commit();
      expect(payload.parameterUpdates['beauty']!['intensity'], 1.0);
    });

    test('GT-12b double below min is clamped to min', () {
      tx.setParameter('beauty', 'intensity', -0.5); // min 0.0
      final payload = tx.commit();
      expect(payload.parameterUpdates['beauty']!['intensity'], 0.0);
    });

    test('GT-12c int above max is clamped to max', () {
      tx.setParameter('beauty', 'beautyVersion', 99); // max 2
      final payload = tx.commit();
      expect(payload.parameterUpdates['beauty']!['beautyVersion'], 2);
    });

    test('GT-12d int below min is clamped to min', () {
      tx.setParameter('beauty', 'beautyVersion', -1); // min 1
      final payload = tx.commit();
      expect(payload.parameterUpdates['beauty']!['beautyVersion'], 1);
    });

    test('GT-12e double inside range passes through unchanged', () {
      tx.setParameter('lut', 'intensity', 0.7);
      final payload = tx.commit();
      expect(payload.parameterUpdates['lut']!['intensity'], 0.7);
    });

    test('GT-12f bool passes through unchanged', () {
      tx.setParameter('beauty', 'faceAwareEnabled', true);
      final payload = tx.commit();
      expect(payload.parameterUpdates['beauty']!['faceAwareEnabled'], isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Last-write-wins
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransaction — last-write-wins', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GT-13a multiple writes to same param keep last clamped value', () {
      tx.setParameter('beauty', 'intensity', 0.3);
      tx.setParameter('beauty', 'intensity', 0.9);
      final payload = tx.commit();
      expect(payload.parameterUpdates['beauty']!['intensity'], 0.9);
    });

    test('GT-13b last-write policy overrides prior policy for same param', () {
      // Write a warm parameter (radius), then overwrite it. Same policy stays.
      tx.setParameter('beauty', 'radius', 1.5);
      tx.setParameter('beauty', 'radius', 3.0);
      final payload = tx.commit();
      expect(payload.parameterUpdates['beauty']!['radius'], 3.0);
      expect(payload.hasWarmParameters, isTrue);
    });

    test('GT-13c last-write preset replaces earlier preset', () {
      tx.applyPreset(makePreset(id: 'first'));
      tx.applyPreset(makePreset(id: 'second'));
      final payload = tx.commit();
      expect(payload.preset?.id, 'second');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Preset + parameter coexistence
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransaction — preset and parameter coexistence', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GT-14a preset and parameter updates both present in payload', () {
      tx.applyPreset(makePreset());
      tx.setParameter('lut', 'intensity', 0.4);
      final payload = tx.commit();
      expect(payload.preset, isNotNull);
      expect(payload.parameterUpdates.containsKey('lut'), isTrue);
    });

    test(
      'GT-14b preset and parameter updates have independent field paths',
      () {
        tx.applyPreset(makePreset(id: 'portrait-soft'));
        tx.setParameter('beauty', 'intensity', 0.8);
        final payload = tx.commit();
        expect(payload.preset!.id, 'portrait-soft');
        expect(payload.parameterUpdates['beauty']!['intensity'], 0.8);
      },
    );

    test(
      'GT-14c coexisting tx: requiresRebuild from preset, hasHotParameters from param',
      () {
        tx.applyPreset(makePreset());
        tx.setParameter('beauty', 'intensity', 0.5); // hot
        final payload = tx.commit();
        expect(payload.requiresRebuild, isTrue);
        expect(payload.hasHotParameters, isTrue);
      },
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Payload immutability
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransactionPayload — immutability', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GT-15a outer parameterUpdates map is unmodifiable', () {
      tx.setParameter('beauty', 'intensity', 0.5);
      final payload = tx.commit();
      // Supply a typed argument so the Map type-check passes and we reach
      // the UnsupportedError from _UnmodifiableMapMixin, not a _TypeError.
      expect(
        () => payload.parameterUpdates.addAll(<String, Map<String, dynamic>>{
          'ghost': {},
        }),
        throwsUnsupportedError,
      );
    });

    test('GT-15b inner parameter map is unmodifiable', () {
      tx.setParameter('beauty', 'intensity', 0.5);
      final payload = tx.commit();
      // The inner map is UnmodifiableMapView — casting to Map<dynamic, dynamic>
      // to avoid a type-cast exception before reaching UnsupportedError.
      expect(
        () =>
            (payload.parameterUpdates['beauty']
                    as Map<dynamic, dynamic>)['ghost'] =
                99,
        throwsUnsupportedError,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // toJson() shape
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransactionPayload — toJson', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GT-16a empty payload toJson has all five keys', () {
      final j = tx.commit().toJson();
      expect(j.containsKey('preset'), isTrue);
      expect(j.containsKey('parameterUpdates'), isTrue);
      expect(j.containsKey('requiresRebuild'), isTrue);
      expect(j.containsKey('hasWarmParameters'), isTrue);
      expect(j.containsKey('hasHotParameters'), isTrue);
    });

    test(
      'GT-16b empty payload: preset null, parameterUpdates empty, flags false',
      () {
        final j = tx.commit().toJson();
        expect(j['preset'], isNull);
        expect(j['parameterUpdates'], isEmpty);
        expect(j['requiresRebuild'], isFalse);
        expect(j['hasWarmParameters'], isFalse);
        expect(j['hasHotParameters'], isFalse);
      },
    );

    test('GT-16c parameter update appears in parameterUpdates', () {
      tx.setParameter('beauty', 'intensity', 0.7);
      final j = tx.commit().toJson();
      final updates = j['parameterUpdates'] as Map<dynamic, dynamic>;
      expect((updates['beauty'] as Map<dynamic, dynamic>)['intensity'], 0.7);
    });

    test('GT-16d preset appears as toJson() shape', () {
      tx.applyPreset(makePreset(id: 'rt', name: 'RT'));
      final j = tx.commit().toJson();
      final presetJson = j['preset'] as Map;
      expect(presetJson['id'], 'rt');
      expect(presetJson['name'], 'RT');
      expect(presetJson.containsKey('filterStack'), isTrue);
    });

    test('GT-16e flags propagate correctly into toJson', () {
      tx.setParameter('beauty', 'intensity', 0.5); // hot
      tx.setParameter('beauty', 'radius', 2.0); // warm
      final j = tx.commit().toJson();
      expect(j['hasHotParameters'], isTrue);
      expect(j['hasWarmParameters'], isTrue);
      expect(j['requiresRebuild'], isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // clear()
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransaction — clear()', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GT-17a clear resets pending parameters', () {
      tx.setParameter('beauty', 'intensity', 0.8);
      tx.clear();
      expect(tx.isEmpty, isTrue);
    });

    test('GT-17b clear resets preset', () {
      tx.applyPreset(makePreset());
      tx.clear();
      expect(tx.isEmpty, isTrue);
    });

    test('GT-17c clear resets all policy flags', () {
      tx.setParameter('beauty', 'intensity', 0.5); // hot
      tx.setParameter('beauty', 'radius', 2.0); // warm
      tx.setParameter('beauty', 'beautyVersion', 2); // prepare
      tx.clear();
      expect(tx.hasHotParameters, isFalse);
      expect(tx.hasWarmParameters, isFalse);
      expect(tx.requiresRebuild, isFalse);
    });

    test('GT-17d after clear, builder can be reused cleanly', () {
      tx.setParameter('beauty', 'intensity', 0.5);
      tx.clear();
      tx.setParameter('lut', 'intensity', 0.2);
      final payload = tx.commit();
      expect(payload.parameterUpdates.containsKey('lut'), isTrue);
      expect(payload.parameterUpdates.containsKey('beauty'), isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Multiple independent commits
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransaction — multiple independent commits', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GT-22a successive commits produce independent payloads', () {
      tx.setParameter('beauty', 'intensity', 0.3);
      final p1 = tx.commit();
      tx.setParameter('lut', 'intensity', 0.7);
      final p2 = tx.commit();

      // p1 has beauty, not lut.
      expect(p1.parameterUpdates.containsKey('beauty'), isTrue);
      expect(p1.parameterUpdates.containsKey('lut'), isFalse);

      // p2 has lut, not beauty.
      expect(p2.parameterUpdates.containsKey('lut'), isTrue);
      expect(p2.parameterUpdates.containsKey('beauty'), isFalse);
    });

    test(
      'GT-22b mutating builder after commit does not change prior payload',
      () {
        tx.setParameter('beauty', 'intensity', 0.5);
        final p1 = tx.commit();
        // After commit the builder is cleared; add something else.
        tx.setParameter('lut', 'intensity', 0.9);
        // p1 must be unaffected.
        expect(p1.parameterUpdates.containsKey('lut'), isFalse);
      },
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Payload isEmpty
  // ───────────────────────────────────────────────────────────────────────────

  group('VGGraphTransactionPayload — isEmpty', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GT-20a payload from empty commit is isEmpty', () {
      expect(tx.commit().isEmpty, isTrue);
    });

    test('GT-20b payload with only parameters is not isEmpty', () {
      tx.setParameter('beauty', 'intensity', 0.5);
      expect(tx.commit().isEmpty, isFalse);
    });

    test('GT-20c payload with only preset is not isEmpty', () {
      tx.applyPreset(makePreset());
      expect(tx.commit().isEmpty, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Package A: Vanguard Unified Camera Green Screen Contract §3
  // greenScreen registered in VGEffectCatalog + setParameters() convenience.
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEffectCatalog — greenScreen registration', () {
    test('GS-CAT-1  greenScreen is a registered effect', () {
      expect(VGEffectCatalog.supportsEffect('greenScreen'), isTrue);
    });

    test('GS-CAT-2  greenScreen accepts all 7 canonical parameters', () {
      const canonicalParams = [
        'backgroundType',
        'argb',
        'imagePath',
        'scaleMode',
        'scale',
        'offsetX',
        'offsetY',
      ];
      for (final name in canonicalParams) {
        expect(
          VGEffectCatalog.supportsParameter('greenScreen', name),
          isTrue,
          reason: '"$name" must be a registered greenScreen parameter',
        );
      }
    });

    test('GS-CAT-3  greenScreen rejects an unknown parameter name', () {
      expect(
        VGEffectCatalog.supportsParameter('greenScreen', 'transform'),
        isFalse,
        reason:
            'a nested "transform" key is not part of the canonical '
            'contract and must not be registered',
      );
      expect(
        VGEffectCatalog.supportsParameter('greenScreen', 'backgroundColor'),
        isFalse,
      );
    });

    test(
      'GS-CAT-4  every greenScreen parameter has VGParameterApplyPolicy.hot',
      () {
        final descriptor = VGEffectCatalog.effect('greenScreen')!;
        for (final entry in descriptor.parameters.entries) {
          expect(
            entry.value.applyPolicy,
            equals(VGParameterApplyPolicy.hot),
            reason:
                '"${entry.key}" must be hot — background/transform '
                'updates must never force a graph rebuild',
          );
        }
      },
    );

    test(
      'GS-CAT-5  scale/offsetX/offsetY carry the canonical min/max/default',
      () {
        final scale = VGEffectCatalog.parameter('greenScreen', 'scale')!;
        expect(scale.minValue, equals(0.25));
        expect(scale.maxValue, equals(3.0));
        expect(scale.defaultValue, equals(1.0));

        final offsetX = VGEffectCatalog.parameter('greenScreen', 'offsetX')!;
        expect(offsetX.minValue, equals(-1.0));
        expect(offsetX.maxValue, equals(1.0));
        expect(offsetX.defaultValue, equals(0.0));

        final offsetY = VGEffectCatalog.parameter('greenScreen', 'offsetY')!;
        expect(offsetY.minValue, equals(-1.0));
        expect(offsetY.maxValue, equals(1.0));
        expect(offsetY.defaultValue, equals(0.0));
      },
    );
  });

  group('VGGraphTransaction — greenScreen parameter clamping', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test('GS-TX-1  scale above max clamps to 3.0', () {
      tx.setParameter('greenScreen', 'scale', 5.0);
      final payload = tx.commit();
      expect(payload.parameterUpdates['greenScreen']!['scale'], 3.0);
    });

    test('GS-TX-2  scale below min clamps to 0.25', () {
      tx.setParameter('greenScreen', 'scale', -1.0);
      final payload = tx.commit();
      expect(payload.parameterUpdates['greenScreen']!['scale'], 0.25);
    });

    test('GS-TX-3  offsetX/offsetY clamp to [-1.0, 1.0]', () {
      tx.setParameter('greenScreen', 'offsetX', 2.0);
      tx.setParameter('greenScreen', 'offsetY', -2.0);
      final payload = tx.commit();
      expect(payload.parameterUpdates['greenScreen']!['offsetX'], 1.0);
      expect(payload.parameterUpdates['greenScreen']!['offsetY'], -1.0);
    });

    test('GS-TX-4  backgroundType/argb/imagePath/scaleMode pass through '
        'unchanged (string/int, no numeric range)', () {
      tx.setParameter('greenScreen', 'backgroundType', 'imageFile');
      tx.setParameter('greenScreen', 'imagePath', '/tmp/bg.jpg');
      tx.setParameter('greenScreen', 'scaleMode', 'aspectFit');
      tx.setParameter('greenScreen', 'argb', 0xFF1B5E20);
      final payload = tx.commit();
      final gs = payload.parameterUpdates['greenScreen']!;
      expect(gs['backgroundType'], 'imageFile');
      expect(gs['imagePath'], '/tmp/bg.jpg');
      expect(gs['scaleMode'], 'aspectFit');
      expect(gs['argb'], 0xFF1B5E20);
    });

    test('GS-TX-5  greenScreen parameters set hasHotParameters, never '
        'requiresRebuild', () {
      tx.setParameter('greenScreen', 'scale', 1.5);
      expect(tx.hasHotParameters, isTrue);
      expect(tx.requiresRebuild, isFalse);
    });

    test('GS-TX-6  unknown greenScreen parameter throws ArgumentError', () {
      expect(
        () => tx.setParameter('greenScreen', 'transform', {'x': 1}),
        throwsArgumentError,
      );
    });
  });

  group('VGGraphTransaction — setParameters() batch convenience', () {
    late VGGraphTransaction tx;
    setUp(() => tx = VGGraphTransaction());

    test(
      'GS-BATCH-1  setParameters applies every entry through setParameter',
      () {
        tx.setParameters('greenScreen', {
          'scale': 1.5,
          'offsetX': 0.2,
          'offsetY': -0.1,
        });
        final payload = tx.commit();
        final gs = payload.parameterUpdates['greenScreen']!;
        expect(gs['scale'], 1.5);
        expect(gs['offsetX'], 0.2);
        expect(gs['offsetY'], -0.1);
      },
    );

    test('GS-BATCH-2  setParameters clamps each value exactly like '
        'setParameter', () {
      tx.setParameters('greenScreen', {'scale': 10.0, 'offsetX': -10.0});
      final payload = tx.commit();
      final gs = payload.parameterUpdates['greenScreen']!;
      expect(gs['scale'], 3.0);
      expect(gs['offsetX'], -1.0);
    });

    test(
      'GS-BATCH-3  setParameters throws ArgumentError for an unknown effect, '
      'exactly like setParameter',
      () {
        expect(
          () => tx.setParameters('ghostFilter', {'x': 1}),
          throwsArgumentError,
        );
      },
    );

    test('GS-BATCH-4  setParameters throws ArgumentError for an unknown '
        'parameter within the map', () {
      expect(
        () => tx.setParameters('greenScreen', {
          'scale': 1.0,
          'transform': {'x': 1},
        }),
        throwsArgumentError,
      );
    });

    test('GS-BATCH-5  entries applied before a failing key remain queued '
        '(fail-fast-per-call, no multi-key rollback)', () {
      try {
        tx.setParameters('greenScreen', {
          'scale': 1.5, // applied first, valid
          'transform': {'x': 1}, // fails — Map iteration is insertion order
        });
      } catch (_) {}
      expect(
        tx.hasHotParameters,
        isTrue,
        reason:
            'the "scale" write before the failing key must remain '
            'queued on the builder',
      );
    });

    test('GS-BATCH-6  setParameters coexists with beauty parameters set via '
        'plain setParameter', () {
      tx.setParameter('beauty', 'intensity', 0.6);
      tx.setParameters('greenScreen', {'scale': 1.2, 'offsetX': 0.0});
      final payload = tx.commit();
      expect(payload.parameterUpdates['beauty']!['intensity'], 0.6);
      expect(payload.parameterUpdates['greenScreen']!['scale'], 1.2);
    });
  });
}
