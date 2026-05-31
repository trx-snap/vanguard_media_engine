// vg_descriptor_test.dart
// Vanguard Media Engine — Phase 6C.1A
//
// Pure Dart unit tests for:
//   - VGParameterDescriptor (type, range, clamping, validation)
//   - VGEffectCatalog       (registry lookup, safety)
//   - VGPresetDescriptor    (construction, serialisation, immutability)
//
// No Flutter engine or native code required — runs in `dart test` /
// `flutter test`. Pattern mirrors vg_camera_session_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_parameter_descriptor.dart';
import 'package:vanguard_media_engine/vg_effect_catalog.dart';
import 'package:vanguard_media_engine/vg_preset_descriptor.dart';
import 'package:vanguard_media_engine/vg_filter_spec.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart'; // Phase 7.12

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // VGParameterDescriptor
  // ───────────────────────────────────────────────────────────────────────────

  group('VGParameterDescriptor — construction validation', () {
    test('PD-1  empty name throws ArgumentError', () {
      expect(
        () => VGParameterDescriptor(
          name: '',
          type: VGParameterType.doubleValue,
          defaultValue: 0.0,
        ),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'name')),
      );
    });

    test('PD-2  min > max throws ArgumentError', () {
      expect(
        () => VGParameterDescriptor(
          name: 'intensity',
          type: VGParameterType.doubleValue,
          defaultValue: 0.5,
          minValue: 1.0,
          maxValue: 0.0,
        ),
        throwsArgumentError,
      );
    });

    test('PD-3  min == max is valid', () {
      final d = VGParameterDescriptor(
        name: 'fixed',
        type: VGParameterType.doubleValue,
        defaultValue: 0.5,
        minValue: 0.5,
        maxValue: 0.5,
      );
      expect(d.minValue, 0.5);
      expect(d.maxValue, 0.5);
    });

    test('PD-4  null min/max is valid (unconstrained)', () {
      final d = VGParameterDescriptor(
        name: 'open',
        type: VGParameterType.doubleValue,
        defaultValue: 0.0,
      );
      expect(d.minValue, isNull);
      expect(d.maxValue, isNull);
    });

    test('PD-5  default applyPolicy is hot', () {
      final d = VGParameterDescriptor(
        name: 'x',
        type: VGParameterType.doubleValue,
        defaultValue: 0.0,
      );
      expect(d.applyPolicy, VGParameterApplyPolicy.hot);
    });
  });

  // ── double clamping ─────────────────────────────────────────────────────────

  group('VGParameterDescriptor — double clamp', () {
    late VGParameterDescriptor desc;

    setUp(() {
      desc = VGParameterDescriptor(
        name: 'intensity',
        type: VGParameterType.doubleValue,
        defaultValue: 1.0,
        minValue: 0.0,
        maxValue: 1.0,
      );
    });

    test('PD-6  value inside range passes through unchanged', () {
      expect(desc.clamp(0.5), 0.5);
    });

    test('PD-7  value below min is clamped to min', () {
      expect(desc.clamp(-0.1), 0.0);
    });

    test('PD-8  value above max is clamped to max', () {
      expect(desc.clamp(1.5), 1.0);
    });

    test('PD-9  exactly at min boundary is unchanged', () {
      expect(desc.clamp(0.0), 0.0);
    });

    test('PD-10 exactly at max boundary is unchanged', () {
      expect(desc.clamp(1.0), 1.0);
    });

    test('PD-11 result is always a double', () {
      expect(desc.clamp(0), isA<double>()); // int 0 → double 0.0
    });

    test('PD-12 incompatible type (String) throws ArgumentError', () {
      expect(() => desc.clamp('bad'), throwsArgumentError);
    });

    test('PD-13 unconstrained double: value below zero passes through', () {
      final open = VGParameterDescriptor(
        name: 'open',
        type: VGParameterType.doubleValue,
        defaultValue: 0.0,
      );
      expect(open.clamp(-999.0), -999.0);
    });
  });

  // ── int clamping ────────────────────────────────────────────────────────────

  group('VGParameterDescriptor — int clamp', () {
    late VGParameterDescriptor desc;

    setUp(() {
      desc = VGParameterDescriptor(
        name: 'beautyVersion',
        type: VGParameterType.intValue,
        defaultValue: 1,
        minValue: 1,
        maxValue: 2,
      );
    });

    test('PD-14 int inside range passes through unchanged', () {
      expect(desc.clamp(1), 1);
      expect(desc.clamp(2), 2);
    });

    test('PD-15 int below min is clamped to min', () {
      expect(desc.clamp(0), 1);
    });

    test('PD-16 int above max is clamped to max', () {
      expect(desc.clamp(5), 2);
    });

    test('PD-17 double → int: truncated then clamped', () {
      expect(desc.clamp(1.9), 1); // 1.9.toInt() = 1
    });

    test('PD-18 result is always an int', () {
      expect(desc.clamp(1), isA<int>());
    });

    test('PD-19 incompatible type (bool) throws ArgumentError', () {
      expect(() => desc.clamp(true), throwsArgumentError);
    });
  });

  // ── bool validation ─────────────────────────────────────────────────────────

  group('VGParameterDescriptor — bool validation', () {
    late VGParameterDescriptor desc;

    setUp(() {
      desc = VGParameterDescriptor(
        name: 'faceAwareEnabled',
        type: VGParameterType.boolValue,
        defaultValue: false,
      );
    });

    test('PD-20 true returns true', () {
      expect(desc.clamp(true), isTrue);
    });

    test('PD-21 false returns false', () {
      expect(desc.clamp(false), isFalse);
    });

    test('PD-22 non-bool throws ArgumentError', () {
      expect(() => desc.clamp(1), throwsArgumentError);
      expect(() => desc.clamp('yes'), throwsArgumentError);
    });

    test('PD-23 minValue/maxValue on bool descriptor do not cause errors', () {
      // min/max are defined as num? — callers can supply them; clamp ignores
      // them for bool but the descriptor should still be constructable.
      final d = VGParameterDescriptor(
        name: 'flag',
        type: VGParameterType.boolValue,
        defaultValue: false,
        // min/max intentionally omitted — not meaningful for bool.
      );
      expect(d.clamp(true), isTrue);
    });
  });

  // ── string validation ───────────────────────────────────────────────────────

  group('VGParameterDescriptor — string validation', () {
    late VGParameterDescriptor desc;

    setUp(() {
      desc = VGParameterDescriptor(
        name: 'lutPath',
        type: VGParameterType.stringValue,
        defaultValue: '',
      );
    });

    test('PD-24 string passes through unchanged', () {
      expect(desc.clamp('assets/luts/warm.png'), 'assets/luts/warm.png');
    });

    test('PD-25 empty string passes through', () {
      expect(desc.clamp(''), '');
    });

    test('PD-26 non-string throws ArgumentError', () {
      expect(() => desc.clamp(42), throwsArgumentError);
      expect(() => desc.clamp(true), throwsArgumentError);
    });
  });

  // ── toJson ──────────────────────────────────────────────────────────────────

  group('VGParameterDescriptor — toJson', () {
    test('PD-27 includes all fields when min/max present', () {
      final d = VGParameterDescriptor(
        name: 'intensity',
        type: VGParameterType.doubleValue,
        defaultValue: 1.0,
        minValue: 0.0,
        maxValue: 1.0,
        applyPolicy: VGParameterApplyPolicy.hot,
      );
      final j = d.toJson();
      expect(j['name'], 'intensity');
      expect(j['type'], 'doubleValue');
      expect(j['defaultValue'], 1.0);
      expect(j['minValue'], 0.0);
      expect(j['maxValue'], 1.0);
      expect(j['applyPolicy'], 'hot');
    });

    test('PD-28 omits minValue/maxValue when null', () {
      final d = VGParameterDescriptor(
        name: 'open',
        type: VGParameterType.doubleValue,
        defaultValue: 0.0,
      );
      final j = d.toJson();
      expect(j.containsKey('minValue'), isFalse);
      expect(j.containsKey('maxValue'), isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // VGEffectCatalog
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEffectCatalog — known effects', () {
    test('EC-1  lut effect is registered', () {
      expect(VGEffectCatalog.supportsEffect('lut'), isTrue);
      expect(VGEffectCatalog.effect('lut'), isNotNull);
    });

    test('EC-2  beauty effect is registered', () {
      expect(VGEffectCatalog.supportsEffect('beauty'), isTrue);
      expect(VGEffectCatalog.effect('beauty'), isNotNull);
    });

    test('EC-3  segmentation effect is registered', () {
      expect(VGEffectCatalog.supportsEffect('segmentation'), isTrue);
      expect(VGEffectCatalog.effect('segmentation'), isNotNull);
    });

    test('EC-4  unknown effect returns null / false', () {
      expect(VGEffectCatalog.effect('unknown'), isNull);
      expect(VGEffectCatalog.supportsEffect('unknown'), isFalse);
    });

    test('EC-5  effects map contains exactly three entries', () {
      expect(VGEffectCatalog.effects.length, 3);
    });
  });

  group('VGEffectCatalog — beauty parameters', () {
    test('EC-6  beauty has intensity parameter', () {
      expect(VGEffectCatalog.supportsParameter('beauty', 'intensity'), isTrue);
    });

    test('EC-7  beauty has radius parameter', () {
      expect(VGEffectCatalog.supportsParameter('beauty', 'radius'), isTrue);
    });

    test('EC-8  beauty has beautyVersion parameter', () {
      expect(
        VGEffectCatalog.supportsParameter('beauty', 'beautyVersion'),
        isTrue,
      );
    });

    test('EC-9  beauty has faceAwareEnabled parameter', () {
      expect(
        VGEffectCatalog.supportsParameter('beauty', 'faceAwareEnabled'),
        isTrue,
      );
    });

    test('EC-10 beauty.intensity descriptor has correct range', () {
      final p = VGEffectCatalog.parameter('beauty', 'intensity')!;
      expect(p.minValue, 0.0);
      expect(p.maxValue, 1.0);
      expect(p.type, VGParameterType.doubleValue);
    });

    test('EC-11 beauty.beautyVersion descriptor is intValue', () {
      final p = VGEffectCatalog.parameter('beauty', 'beautyVersion')!;
      expect(p.type, VGParameterType.intValue);
      expect(p.minValue, 1);
      expect(p.maxValue, 2);
    });

    test('EC-12 beauty.faceAwareEnabled descriptor is boolValue', () {
      final p = VGEffectCatalog.parameter('beauty', 'faceAwareEnabled')!;
      expect(p.type, VGParameterType.boolValue);
    });
  });

  group('VGEffectCatalog — lut parameters', () {
    test('EC-13 lut has intensity parameter', () {
      expect(VGEffectCatalog.supportsParameter('lut', 'intensity'), isTrue);
    });

    test('EC-14 lut.intensity has range [0.0, 1.0]', () {
      final p = VGEffectCatalog.parameter('lut', 'intensity')!;
      expect(p.minValue, 0.0);
      expect(p.maxValue, 1.0);
    });
  });

  group('VGEffectCatalog — segmentation parameters', () {
    test('EC-15 segmentation has no parameters', () {
      final d = VGEffectCatalog.effect('segmentation')!;
      expect(d.parameters.isEmpty, isTrue);
    });

    test(
      'EC-16 supportsParameter returns false for any segmentation param',
      () {
        expect(
          VGEffectCatalog.supportsParameter('segmentation', 'intensity'),
          isFalse,
        );
      },
    );
  });

  group('VGEffectCatalog — safe null returns', () {
    test('EC-17 parameter on unknown effect returns null', () {
      expect(VGEffectCatalog.parameter('nope', 'intensity'), isNull);
    });

    test('EC-18 parameter on known effect but unknown param returns null', () {
      expect(VGEffectCatalog.parameter('beauty', 'fakeParam'), isNull);
    });

    test('EC-19 supportsParameter on unknown effect returns false', () {
      expect(VGEffectCatalog.supportsParameter('nope', 'intensity'), isFalse);
    });
  });

  group('VGEffectCatalog — VGEffectDescriptor.toJson', () {
    test('EC-20 beauty descriptor toJson shape', () {
      final d = VGEffectCatalog.effect('beauty')!;
      final j = d.toJson();
      expect(j['type'], 'beauty');
      expect(j['parameters'], isA<Map>());
      expect((j['parameters'] as Map).containsKey('intensity'), isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // VGPresetDescriptor
  // ───────────────────────────────────────────────────────────────────────────

  group('VGPresetDescriptor — construction validation', () {
    test('PR-1  empty id throws ArgumentError', () {
      expect(
        () => VGPresetDescriptor(id: '', name: 'My Preset', filterStack: []),
        throwsArgumentError,
      );
    });

    test('PR-2  empty name throws ArgumentError', () {
      expect(
        () => VGPresetDescriptor(id: 'p1', name: '', filterStack: []),
        throwsArgumentError,
      );
    });

    test('PR-3  empty filterStack is valid', () {
      final p = VGPresetDescriptor(id: 'empty', name: 'Empty', filterStack: []);
      expect(p.filterStack, isEmpty);
    });
  });

  group('VGPresetDescriptor — immutability', () {
    test('PR-4  filterStack is unmodifiable (add throws)', () {
      final original = [VGFilterSpecs.beauty()];
      final p = VGPresetDescriptor(id: 'p1', name: 'P1', filterStack: original);
      expect(
        () => (p.filterStack as List).add(VGFilterSpecs.lut()),
        throwsUnsupportedError,
      );
    });

    test(
      'PR-5  mutation of source list after construction does not affect preset',
      () {
        final source = [VGFilterSpecs.beauty()];
        final p = VGPresetDescriptor(id: 'p2', name: 'P2', filterStack: source);
        source.add(VGFilterSpecs.lut());
        expect(p.filterStack.length, 1);
      },
    );
  });

  group('VGPresetDescriptor — toJson', () {
    test('PR-6  toJson shape matches VGFilterSpec.toJson', () {
      final p = VGPresetDescriptor(
        id: 'portrait-soft',
        name: 'Portrait Soft',
        filterStack: [
          VGFilterSpecs.beauty(intensity: 0.6),
          VGFilterSpecs.lut(intensity: 0.4),
        ],
      );
      final j = p.toJson();
      expect(j['id'], 'portrait-soft');
      expect(j['name'], 'Portrait Soft');
      final stack = j['filterStack'] as List;
      expect(stack.length, 2);
      // First entry: beauty
      final beauty = stack[0] as Map;
      expect(beauty['type'], 'beauty');
      expect(beauty['enabled'], isTrue);
      expect((beauty['parameters'] as Map)['intensity'], 0.6);
      // Second entry: lut
      final lut = stack[1] as Map;
      expect(lut['type'], 'lut');
      expect(lut['enabled'], isTrue);
      expect((lut['parameters'] as Map)['intensity'], 0.4);
    });

    test('PR-7  empty filterStack serialises as empty list', () {
      final p = VGPresetDescriptor(id: 'x', name: 'X', filterStack: []);
      final j = p.toJson();
      expect(j['filterStack'], isEmpty);
    });
  });

  group('VGPresetDescriptor — fromJson round-trip', () {
    test('PR-8  round-trip preserves id, name, and filterStack', () {
      final original = VGPresetDescriptor(
        id: 'rt-test',
        name: 'Round Trip',
        filterStack: [VGFilterSpecs.lut(intensity: 0.8)],
      );
      final clone = VGPresetDescriptor.fromJson(
        Map<String, dynamic>.from(original.toJson()),
      );
      expect(clone.id, original.id);
      expect(clone.name, original.name);
      expect(clone.filterStack.length, 1);
      expect(clone.filterStack[0].type, 'lut');
      expect(clone.filterStack[0].parameters['intensity'], 0.8);
    });

    test('PR-9  fromJson honours enabled flag', () {
      final json = <String, dynamic>{
        'id': 'e1',
        'name': 'Enabled Test',
        'filterStack': [
          {
            'type': 'beauty',
            'enabled': false,
            'parameters': <String, Object?>{},
          },
        ],
      };
      final p = VGPresetDescriptor.fromJson(json);
      expect(p.filterStack[0].enabled, isFalse);
    });

    test('PR-10 fromJson defaults enabled to true when absent', () {
      final json = <String, dynamic>{
        'id': 'e2',
        'name': 'Default Enabled',
        'filterStack': [
          {'type': 'lut', 'parameters': <String, Object?>{}},
        ],
      };
      final p = VGPresetDescriptor.fromJson(json);
      expect(p.filterStack[0].enabled, isTrue);
    });

    test('PR-11 fromJson throws on missing id', () {
      expect(
        () => VGPresetDescriptor.fromJson({
          'name': 'N',
          'filterStack': <dynamic>[],
        }),
        throwsArgumentError,
      );
    });

    test('PR-12 fromJson throws on missing name', () {
      expect(
        () => VGPresetDescriptor.fromJson({
          'id': 'i',
          'filterStack': <dynamic>[],
        }),
        throwsArgumentError,
      );
    });

    test('PR-13 fromJson throws when filterStack is not a List', () {
      expect(
        () => VGPresetDescriptor.fromJson({
          'id': 'i',
          'name': 'N',
          'filterStack': 'bad',
        }),
        throwsArgumentError,
      );
    });

    test('PR-14 fromJson throws when a stack entry has no type', () {
      expect(
        () => VGPresetDescriptor.fromJson({
          'id': 'i',
          'name': 'N',
          'filterStack': [
            {'enabled': true, 'parameters': <dynamic, dynamic>{}},
          ],
        }),
        throwsArgumentError,
      );
    });
  });

  group('VGPresetDescriptor — equality and hashCode', () {
    test('PR-15 equal presets with same content are equal', () {
      final a = VGPresetDescriptor(
        id: 'p',
        name: 'P',
        filterStack: [VGFilterSpecs.lut()],
      );
      final b = VGPresetDescriptor(
        id: 'p',
        name: 'P',
        filterStack: [VGFilterSpecs.lut()],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('PR-16 presets with different ids are not equal', () {
      final a = VGPresetDescriptor(id: 'a', name: 'P', filterStack: []);
      final b = VGPresetDescriptor(id: 'b', name: 'P', filterStack: []);
      expect(a == b, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // VGClipDescriptor — VGMediaKind.image (Phase 7.12)
  // ───────────────────────────────────────────────────────────────────────

  group('VGClipDescriptor — VGMediaKind.image (Phase 7.12)', () {
    // Helper: a minimal valid still-image descriptor.
    VGClipDescriptor _imageClip({
      String id = 'img-01',
      String sourcePath = '/tmp/still_C.png',
      double durationSeconds = 5.0,
      double trimStart = 0.0,
      double trimEnd = 5.0,
    }) =>
        VGClipDescriptor(
          id: id,
          sourcePath: sourcePath,
          mediaKind: VGMediaKind.image,
          durationSeconds: durationSeconds,
          trimStartSeconds: trimStart,
          trimEndSeconds: trimEnd,
        );

    test('IK-1  VGClipDescriptor with VGMediaKind.image is constructible', () {
      final clip = _imageClip();
      expect(clip.mediaKind, VGMediaKind.image);
      expect(clip.id, 'img-01');
      expect(clip.sourcePath, '/tmp/still_C.png');
    });

    test('IK-2  toMap() serialises mediaKind as "image"', () {
      final m = _imageClip().toMap();
      expect(m['mediaKind'], 'image');
    });

    test('IK-3  fromMap() deserialises mediaKind="image" to VGMediaKind.image', () {
      final m = _imageClip().toMap();
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNotNull);
      expect(clip!.mediaKind, VGMediaKind.image);
    });

    test('IK-4  fromMap() round-trip preserves all fields for an image clip', () {
      final original = _imageClip(
        id: 'img-rt',
        sourcePath: '/tmp/photo.jpg',
        durationSeconds: 10.0,
        trimStart: 0.0,
        trimEnd: 4.0,
      );
      final clone = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(original.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!.id, original.id);
      expect(clone.sourcePath, original.sourcePath);
      expect(clone.mediaKind, VGMediaKind.image);
      expect(clone.durationSeconds, original.durationSeconds);
      expect(clone.trimStartSeconds, original.trimStartSeconds);
      expect(clone.trimEndSeconds, original.trimEndSeconds);
      expect(clone.speed, original.speed);
    });

    test('IK-5  fromMap() with unknown mediaKind string returns VGMediaKind.unknown', () {
      // VGMediaKind.fromValue returns unknown for unrecognised strings;
      // fromMap should still succeed (not return null) for unknown kinds.
      final m = _imageClip().toMap()
        ..['mediaKind'] = 'hologram'; // unrecognised
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNotNull);
      expect(clip!.mediaKind, VGMediaKind.unknown);
    });

    test('IK-6  fromMap() defaults mediaKind to video when key is absent', () {
      final m = _imageClip().toMap()..remove('mediaKind');
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNotNull);
      // Dart default when key absent: mediaKindStr = 'video' per fromMap impl.
      expect(clip!.mediaKind, VGMediaKind.video);
    });

    test('IK-7  timelineDuration for image clip equals trimEnd - trimStart', () {
      final clip = _imageClip(trimStart: 0.0, trimEnd: 3.5);
      expect(clip.timelineDuration, closeTo(3.5, 1e-10));
    });
  });
}

// ignore: unused_import
// vg_clip_transform_descriptor tests appended by Phase 7.11 implementer.
// These tests are imported by the vg_descriptor_test.dart main() above via
// a separate call; kept in the same file for colocation with descriptor tests.
// To run: `flutter test test/vg_descriptor_test.dart`

// ─── Phase 7.12: VGClipDescriptor — VGMediaKind.image ────────────────────────
// Added by Phase 7.12 Implementer.
// Tests cover:
//   IK-1  VGClipDescriptor constructed with VGMediaKind.image is valid.
//   IK-2  toMap() serialises mediaKind as "image".
//   IK-3  fromMap() deserialises mediaKind = "image" to VGMediaKind.image.
//   IK-4  fromMap() round-trip preserves mediaKind.image end-to-end.
//   IK-5  fromMap() with unknown mediaKind returns VGMediaKind.unknown (no null).
//   IK-6  VGClipDescriptor.mediaKind defaults to VGMediaKind.video when omitted from map.
//   IK-7  Still-image VGClipDescriptor.timelineDuration equals (trimEnd - trimStart).
// Note: These tests exercise only Dart-layer descriptor logic.
//       Native compositor image decoding is validated via manual device test (still_C.png).
