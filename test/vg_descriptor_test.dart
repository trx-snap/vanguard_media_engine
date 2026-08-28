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
import 'package:vanguard_media_engine/vg_editor_draft.dart'; // Phase 7.17

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
    }) => VGClipDescriptor(
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

    test(
      'IK-3  fromMap() deserialises mediaKind="image" to VGMediaKind.image',
      () {
        final m = _imageClip().toMap();
        final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
        expect(clip, isNotNull);
        expect(clip!.mediaKind, VGMediaKind.image);
      },
    );

    test(
      'IK-4  fromMap() round-trip preserves all fields for an image clip',
      () {
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
      },
    );

    test(
      'IK-5  fromMap() with unknown mediaKind string returns VGMediaKind.unknown',
      () {
        // VGMediaKind.fromValue returns unknown for unrecognised strings;
        // fromMap should still succeed (not return null) for unknown kinds.
        final m = _imageClip().toMap()
          ..['mediaKind'] = 'hologram'; // unrecognised
        final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
        expect(clip, isNotNull);
        expect(clip!.mediaKind, VGMediaKind.unknown);
      },
    );

    test('IK-6  fromMap() defaults mediaKind to video when key is absent', () {
      final m = _imageClip().toMap()..remove('mediaKind');
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNotNull);
      // Dart default when key absent: mediaKindStr = 'video' per fromMap impl.
      expect(clip!.mediaKind, VGMediaKind.video);
    });

    test(
      'IK-7  timelineDuration for image clip equals trimEnd - trimStart',
      () {
        final clip = _imageClip(trimStart: 0.0, trimEnd: 3.5);
        expect(clip.timelineDuration, closeTo(3.5, 1e-10));
      },
    );

    // ── Phase 7.16: VGStillImageFitMode and cropRect ─────────────────────────
    // Tests added by Phase 7.16 Implementer.

    test('IK-8  fitMode defaults to VGStillImageFitMode.fit', () {
      final clip = _imageClip();
      expect(clip.fitMode, VGStillImageFitMode.fit);
    });

    test('IK-9  cropRect defaults to null', () {
      final clip = _imageClip();
      expect(clip.cropRect, isNull);
      expect(clip.cropX, isNull);
      expect(clip.cropY, isNull);
      expect(clip.cropWidth, isNull);
      expect(clip.cropHeight, isNull);
    });

    test('IK-10 fitMode=fill serialises to "fill" in toMap()', () {
      final clip = VGClipDescriptor(
        id: 'img-fill',
        sourcePath: '/tmp/img.jpg',
        mediaKind: VGMediaKind.image,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        fitMode: VGStillImageFitMode.fill,
      );
      final m = clip.toMap();
      expect(m['fitMode'], 'fill');
    });

    test('IK-11 fitMode=fit is omitted from toMap() (default omit style)', () {
      final clip = _imageClip();
      final m = clip.toMap();
      expect(m.containsKey('fitMode'), isFalse);
    });

    test('IK-12 fitMode round-trip via fromMap() preserves fill', () {
      final original = VGClipDescriptor(
        id: 'img-rt-fill',
        sourcePath: '/tmp/img.jpg',
        mediaKind: VGMediaKind.image,
        durationSeconds: 5.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 5.0,
        fitMode: VGStillImageFitMode.fill,
      );
      final clone = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(original.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!.fitMode, VGStillImageFitMode.fill);
    });

    test('IK-13 fitMode defaults to fit when key absent in fromMap()', () {
      final m = _imageClip().toMap()..remove('fitMode');
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNotNull);
      expect(clip!.fitMode, VGStillImageFitMode.fit);
    });

    test('IK-14 unknown fitMode string resolves to fit (safe default)', () {
      final m = _imageClip().toMap();
      m['fitMode'] = 'stretch'; // unrecognised
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNotNull);
      expect(clip!.fitMode, VGStillImageFitMode.fit);
    });

    test('IK-15 cropRect [0.1, 0.2, 0.6, 0.5] round-trip via fromMap()', () {
      final original = VGClipDescriptor(
        id: 'img-crop',
        sourcePath: '/tmp/img.jpg',
        mediaKind: VGMediaKind.image,
        durationSeconds: 4.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 4.0,
        cropRect: [0.1, 0.2, 0.6, 0.5],
      );
      final clone = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(original.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!.cropRect, isNotNull);
      expect(clone.cropRect, hasLength(4));
      expect(clone.cropX, closeTo(0.1, 1e-10));
      expect(clone.cropY, closeTo(0.2, 1e-10));
      expect(clone.cropWidth, closeTo(0.6, 1e-10));
      expect(clone.cropHeight, closeTo(0.5, 1e-10));
    });

    test('IK-16 cropRect null is omitted from toMap()', () {
      final m = _imageClip().toMap();
      expect(m.containsKey('cropRect'), isFalse);
    });

    test('IK-17 copyWith preserves fitMode when not overridden', () {
      final clip = VGClipDescriptor(
        id: 'img-cw',
        sourcePath: '/tmp/img.jpg',
        mediaKind: VGMediaKind.image,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        fitMode: VGStillImageFitMode.fill,
        cropRect: [0.1, 0.1, 0.8, 0.8],
      );
      final copy = clip.copyWith(id: 'img-cw-2');
      expect(copy.fitMode, VGStillImageFitMode.fill);
      expect(copy.cropRect, [0.1, 0.1, 0.8, 0.8]);
    });

    test('IK-18 copyWith can update fitMode', () {
      final clip = _imageClip();
      final copy = clip.copyWith(fitMode: VGStillImageFitMode.fill);
      expect(copy.fitMode, VGStillImageFitMode.fill);
    });

    test('IK-19 copyWith can clear cropRect to null via sentinel', () {
      final clip = VGClipDescriptor(
        id: 'img-sentinel',
        sourcePath: '/tmp/img.jpg',
        mediaKind: VGMediaKind.image,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        cropRect: [0.0, 0.0, 1.0, 1.0],
      );
      final cleared = clip.copyWith(cropRect: null);
      expect(cleared.cropRect, isNull);
    });

    test('IK-20 equality includes fitMode and cropRect', () {
      final a = VGClipDescriptor(
        id: 'eq-a',
        sourcePath: '/tmp/img.jpg',
        mediaKind: VGMediaKind.image,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        fitMode: VGStillImageFitMode.fill,
        cropRect: [0.1, 0.1, 0.5, 0.5],
      );
      final b = VGClipDescriptor(
        id: 'eq-a',
        sourcePath: '/tmp/img.jpg',
        mediaKind: VGMediaKind.image,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        fitMode: VGStillImageFitMode.fill,
        cropRect: [0.1, 0.1, 0.5, 0.5],
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('IK-21 equality differs when fitMode differs', () {
      final a = _imageClip();
      final b = VGClipDescriptor(
        id: a.id,
        sourcePath: a.sourcePath,
        mediaKind: a.mediaKind,
        durationSeconds: a.durationSeconds,
        trimStartSeconds: a.trimStartSeconds,
        trimEndSeconds: a.trimEndSeconds,
        fitMode: VGStillImageFitMode.fill,
      );
      expect(a == b, isFalse);
    });

    test('IK-22 equality differs when cropRect differs', () {
      final base = VGClipDescriptor(
        id: 'eq-crop',
        sourcePath: '/tmp/img.jpg',
        mediaKind: VGMediaKind.image,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        cropRect: [0.1, 0.1, 0.5, 0.5],
      );
      final other = VGClipDescriptor(
        id: 'eq-crop',
        sourcePath: '/tmp/img.jpg',
        mediaKind: VGMediaKind.image,
        durationSeconds: 3.0,
        trimStartSeconds: 0.0,
        trimEndSeconds: 3.0,
        cropRect: [0.2, 0.2, 0.5, 0.5],
      );
      expect(base == other, isFalse);
    });

    // ── Crop rect validation ──────────────────────────────────────────────────

    test(
      'CV-1  cropRect with wrong length (3 elements) is rejected by fromMap()',
      () {
        final m = _imageClip().toMap();
        m['cropRect'] = [0.1, 0.1, 0.8]; // length 3 — invalid
        final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
        expect(clip, isNull);
      },
    );

    test('CV-2  cropRect with length 5 is rejected by fromMap()', () {
      final m = _imageClip().toMap();
      m['cropRect'] = [0.1, 0.1, 0.5, 0.5, 0.0]; // length 5 — invalid
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNull);
    });

    test('CV-3  cropRect with x < 0 is rejected by fromMap()', () {
      final m = _imageClip().toMap();
      m['cropRect'] = [-0.1, 0.0, 0.5, 0.5];
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNull);
    });

    test('CV-4  cropRect with width == 0 is rejected by fromMap()', () {
      final m = _imageClip().toMap();
      m['cropRect'] = [0.0, 0.0, 0.0, 0.5];
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNull);
    });

    test('CV-5  cropRect with height == 0 is rejected by fromMap()', () {
      final m = _imageClip().toMap();
      m['cropRect'] = [0.0, 0.0, 0.5, 0.0];
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNull);
    });

    test('CV-6  cropRect x + width > 1.0 is rejected by fromMap()', () {
      final m = _imageClip().toMap();
      m['cropRect'] = [0.8, 0.0, 0.5, 0.5]; // 0.8 + 0.5 = 1.3 > 1.0
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNull);
    });

    test('CV-7  cropRect y + height > 1.0 is rejected by fromMap()', () {
      final m = _imageClip().toMap();
      m['cropRect'] = [0.0, 0.8, 0.5, 0.5]; // 0.8 + 0.5 = 1.3 > 1.0
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNull);
    });

    test('CV-8  cropRect with value > 1.0 is rejected by fromMap()', () {
      final m = _imageClip().toMap();
      m['cropRect'] = [0.0, 0.0, 1.5, 0.5]; // width 1.5 out of range
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNull);
    });

    test(
      'CV-9  valid cropRect [0.0, 0.0, 1.0, 1.0] (full frame) is accepted',
      () {
        final clip = VGClipDescriptor(
          id: 'cv-full',
          sourcePath: '/tmp/img.jpg',
          mediaKind: VGMediaKind.image,
          durationSeconds: 3.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 3.0,
          cropRect: [0.0, 0.0, 1.0, 1.0],
        );
        expect(clip.cropRect, isNotNull);
      },
    );

    test('CV-10 VGStillImageFitMode.fromValue("fill") resolves to fill', () {
      expect(VGStillImageFitMode.fromValue('fill'), VGStillImageFitMode.fill);
    });

    test('CV-11 VGStillImageFitMode.fromValue("fit") resolves to fit', () {
      expect(VGStillImageFitMode.fromValue('fit'), VGStillImageFitMode.fit);
    });

    test(
      'CV-12 VGStillImageFitMode.fromValue unknown string resolves to fit',
      () {
        expect(
          VGStillImageFitMode.fromValue('stretch'),
          VGStillImageFitMode.fit,
        );
      },
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Phase 7.17: VGClipDescriptor freezePTS
  // ───────────────────────────────────────────────────────────────────────────

  group('VGClipDescriptor — freezePTS (Phase 7.17)', () {
    // Helper: a minimal valid video clip.
    VGClipDescriptor _videoClip({
      String id = 'vid-01',
      String sourcePath = '/tmp/video.mp4',
      double durationSeconds = 10.0,
      double trimStart = 0.0,
      double trimEnd = 10.0,
      double? freezePTS,
    }) => VGClipDescriptor(
      id: id,
      sourcePath: sourcePath,
      mediaKind: VGMediaKind.video,
      durationSeconds: durationSeconds,
      trimStartSeconds: trimStart,
      trimEndSeconds: trimEnd,
      freezePTS: freezePTS,
    );

    test('FF-1  freezePTS defaults to null', () {
      final clip = _videoClip();
      expect(clip.freezePTS, isNull);
    });

    test('FF-2  non-null freezePTS is stored correctly', () {
      final clip = _videoClip(freezePTS: 3.5);
      expect(clip.freezePTS, closeTo(3.5, 1e-10));
    });

    test('FF-3  zero freezePTS is valid (non-negative boundary)', () {
      final clip = _videoClip(freezePTS: 0.0);
      expect(clip.freezePTS, 0.0);
    });

    test('FF-4  freezePTS=3.0 serialises to toMap()', () {
      final clip = _videoClip(freezePTS: 3.0);
      final m = clip.toMap();
      expect(m.containsKey('freezePTS'), isTrue);
      expect(m['freezePTS'], closeTo(3.0, 1e-10));
    });

    test('FF-5  null freezePTS is omitted from toMap()', () {
      final clip = _videoClip();
      final m = clip.toMap();
      expect(m.containsKey('freezePTS'), isFalse);
    });

    test('FF-6  freezePTS round-trip via fromMap()', () {
      final original = _videoClip(freezePTS: 4.25);
      final clone = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(original.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!.freezePTS, closeTo(4.25, 1e-10));
    });

    test('FF-7  absent freezePTS key in fromMap() returns null', () {
      final m = _videoClip().toMap();
      expect(m.containsKey('freezePTS'), isFalse);
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNotNull);
      expect(clip!.freezePTS, isNull);
    });

    test('FF-8  negative freezePTS is rejected by fromMap()', () {
      final m = _videoClip().toMap();
      m['freezePTS'] = -1.0;
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNull);
    });

    test('FF-9  copyWith preserves freezePTS when not overridden', () {
      final clip = _videoClip(freezePTS: 2.0);
      final copy = clip.copyWith(id: 'vid-copy');
      expect(copy.freezePTS, closeTo(2.0, 1e-10));
    });

    test('FF-10 copyWith can clear freezePTS to null via sentinel', () {
      final clip = _videoClip(freezePTS: 2.0);
      final cleared = clip.copyWith(freezePTS: null);
      expect(cleared.freezePTS, isNull);
    });

    test('FF-11 equality includes freezePTS', () {
      final a = _videoClip(freezePTS: 3.0);
      final b = _videoClip(freezePTS: 3.0);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('FF-12 equality differs when freezePTS differs', () {
      final a = _videoClip(freezePTS: 3.0);
      final b = _videoClip(freezePTS: 4.0);
      expect(a == b, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Phase 7.17: VGEditorDraft.freezeClip
  // ───────────────────────────────────────────────────────────────────────────

  group('VGEditorDraft.freezeClip — Phase 7.17', () {
    // Helper: a draft with a single 10s video clip.
    VGEditorDraft _singleClipDraft() => VGEditorDraft.sequentialWithTransitions(
      id: 'draft-freeze',
      clips: [
        VGClipDescriptor(
          id: 'clip-A',
          sourcePath: '/tmp/video.mp4',
          mediaKind: VGMediaKind.video,
          durationSeconds: 10.0,
          trimStartSeconds: 0.0,
          trimEndSeconds: 10.0,
        ),
      ],
      transitions: const [],
      canvasWidth: 1920,
      canvasHeight: 1080,
      fps: 30,
    );

    test('FC-1  freezeClip returns a draft with 3 clips', () {
      final result = _singleClipDraft().freezeClip('clip-A', 5.0, 2.0);
      expect(result.clips.length, 3);
    });

    test('FC-2  left clip retains original ID with correct trimEnd', () {
      final result = _singleClipDraft().freezeClip('clip-A', 5.0, 2.0);
      final left = result.clips[0];
      expect(left.id, 'clip-A');
      expect(left.trimEndSeconds, closeTo(5.0, 1e-10));
      expect(left.trimStartSeconds, closeTo(0.0, 1e-10));
      expect(left.freezePTS, isNull);
    });

    test('FC-3  freeze clip has correct ID, freezePTS, and hold duration', () {
      final result = _singleClipDraft().freezeClip('clip-A', 5.0, 2.0);
      final freeze = result.clips[1];
      expect(freeze.id, 'clip-A-freeze-1');
      expect(freeze.freezePTS, closeTo(5.0, 1e-10));
      expect(freeze.durationSeconds, closeTo(2.0, 1e-10));
      expect(freeze.trimStartSeconds, closeTo(0.0, 1e-10));
      expect(freeze.trimEndSeconds, closeTo(2.0, 1e-10));
      expect(freeze.speed, 1.0);
      expect(freeze.mediaKind, VGMediaKind.video);
    });

    test('FC-4  right clip has correct split ID and trimStart', () {
      final result = _singleClipDraft().freezeClip('clip-A', 5.0, 2.0);
      final right = result.clips[2];
      expect(right.id, 'clip-A-split-1');
      expect(right.trimStartSeconds, closeTo(5.0, 1e-10));
      expect(right.trimEndSeconds, closeTo(10.0, 1e-10));
      expect(right.freezePTS, isNull);
    });

    test('FC-5  throws ArgumentError for unknown clipId', () {
      expect(
        () => _singleClipDraft().freezeClip('no-such-clip', 5.0, 2.0),
        throwsArgumentError,
      );
    });

    test('FC-6  throws ArgumentError when splitSeconds out of trim window', () {
      expect(
        () => _singleClipDraft().freezeClip('clip-A', 0.0, 2.0),
        throwsArgumentError,
      );
      expect(
        () => _singleClipDraft().freezeClip('clip-A', 10.0, 2.0),
        throwsArgumentError,
      );
    });

    test('FC-7  throws ArgumentError for non-positive duration', () {
      expect(
        () => _singleClipDraft().freezeClip('clip-A', 5.0, 0.0),
        throwsArgumentError,
      );
      expect(
        () => _singleClipDraft().freezeClip('clip-A', 5.0, -1.0),
        throwsArgumentError,
      );
    });

    test('FC-8  throws ArgumentError when clip is not a video clip', () {
      final draft = VGEditorDraft.sequentialWithTransitions(
        id: 'draft-img',
        clips: [
          VGClipDescriptor(
            id: 'img-clip',
            sourcePath: '/tmp/img.jpg',
            mediaKind: VGMediaKind.image,
            durationSeconds: 5.0,
            trimStartSeconds: 0.0,
            trimEndSeconds: 5.0,
          ),
        ],
        transitions: const [],
        canvasWidth: 1920,
        canvasHeight: 1080,
        fps: 30,
      );
      expect(() => draft.freezeClip('img-clip', 2.0, 1.0), throwsArgumentError);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Phase 7.19B: VGClipDescriptor.isReversed
  // ───────────────────────────────────────────────────────────────────────────

  group('VGClipDescriptor — isReversed (Phase 7.19B)', () {
    // Helper: minimal valid video clip.
    VGClipDescriptor _videoClipRV({
      String id = 'vid-rv',
      bool isReversed = false,
    }) => VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/video.mp4',
      mediaKind: VGMediaKind.video,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      isReversed: isReversed,
    );

    test('RV-1  isReversed defaults to false', () {
      final clip = _videoClipRV();
      expect(clip.isReversed, isFalse);
    });

    test('RV-2  isReversed=true is stored correctly', () {
      final clip = _videoClipRV(isReversed: true);
      expect(clip.isReversed, isTrue);
    });

    test('RV-3  false isReversed is omitted from toMap() (wire-minimal)', () {
      final clip = _videoClipRV(isReversed: false);
      final m = clip.toMap();
      expect(m.containsKey('isReversed'), isFalse);
    });

    test('RV-4  true isReversed serialises to toMap() as true', () {
      final clip = _videoClipRV(isReversed: true);
      final m = clip.toMap();
      expect(m.containsKey('isReversed'), isTrue);
      expect(m['isReversed'], isTrue);
    });

    test('RV-5  isReversed=true round-trips via fromMap()', () {
      final original = _videoClipRV(isReversed: true);
      final clone = VGClipDescriptor.fromMap(
        Map<Object?, Object?>.from(original.toMap()),
      );
      expect(clone, isNotNull);
      expect(clone!.isReversed, isTrue);
    });

    test('RV-6  absent isReversed key in fromMap() defaults to false', () {
      final m = _videoClipRV().toMap();
      expect(m.containsKey('isReversed'), isFalse);
      final clip = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
      expect(clip, isNotNull);
      expect(clip!.isReversed, isFalse);
    });

    test('RV-7  copyWith preserves isReversed when not overridden', () {
      final clip = _videoClipRV(isReversed: true);
      final copy = clip.copyWith(id: 'vid-rv-copy');
      expect(copy.isReversed, isTrue);
    });

    test('RV-8  copyWith can set isReversed to true from false', () {
      final clip = _videoClipRV(isReversed: false);
      final reversed = clip.copyWith(isReversed: true);
      expect(reversed.isReversed, isTrue);
    });

    test('RV-9  equality includes isReversed', () {
      final a = _videoClipRV(isReversed: true);
      final b = _videoClipRV(isReversed: true);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('RV-10 equality differs when isReversed differs', () {
      final a = _videoClipRV(isReversed: false);
      final b = _videoClipRV(isReversed: true);
      expect(a == b, isFalse);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Phase 5-Unit O: VGClipDescriptor.sourceRoiSidecarPath
  // ───────────────────────────────────────────────────────────────────────────

  group('VGClipDescriptor — sourceRoiSidecarPath (Phase 5-Unit O)', () {
    VGClipDescriptor clipWithSidecar({
      String id = 'clip-roi',
      String? sourceRoiSidecarPath,
    }) => VGClipDescriptor(
      id: id,
      sourcePath: '/tmp/video.mp4',
      mediaKind: VGMediaKind.video,
      durationSeconds: 10.0,
      trimStartSeconds: 0.0,
      trimEndSeconds: 10.0,
      sourceRoiSidecarPath: sourceRoiSidecarPath,
    );

    test('SR-1  sourceRoiSidecarPath defaults to null', () {
      final clip = clipWithSidecar();
      expect(clip.sourceRoiSidecarPath, isNull);
    });

    test('SR-2  non-null sourceRoiSidecarPath is stored correctly', () {
      final clip = clipWithSidecar(
        sourceRoiSidecarPath: '/tmp/custom/source.roi.json',
      );
      expect(clip.sourceRoiSidecarPath, '/tmp/custom/source.roi.json');
    });

    test('SR-3  null sourceRoiSidecarPath is omitted from toMap()', () {
      final clip = clipWithSidecar();
      final m = clip.toMap();
      expect(m.containsKey('sourceRoiSidecarPath'), isFalse);
    });

    test('SR-4  empty sourceRoiSidecarPath is omitted from toMap()', () {
      final clip = clipWithSidecar(sourceRoiSidecarPath: '');
      final m = clip.toMap();
      expect(m.containsKey('sourceRoiSidecarPath'), isFalse);
    });

    test(
      'SR-5  non-empty sourceRoiSidecarPath serialises to toMap() under sourceRoiSidecarPath',
      () {
        final clip = clipWithSidecar(
          sourceRoiSidecarPath: '/custom/path.roi.json',
        );
        final m = clip.toMap();
        expect(m['sourceRoiSidecarPath'], '/custom/path.roi.json');
      },
    );

    test(
      'SR-6  sourceRoiSidecarPath round-trips via fromMap() when non-empty',
      () {
        final original = clipWithSidecar(
          sourceRoiSidecarPath: '/var/data/capture.roi.json',
        );
        final clone = VGClipDescriptor.fromMap(
          Map<Object?, Object?>.from(original.toMap()),
        );
        expect(clone, isNotNull);
        expect(clone!.sourceRoiSidecarPath, '/var/data/capture.roi.json');
      },
    );

    test(
      'SR-7  absent sourceRoiSidecarPath key in fromMap() defaults to null',
      () {
        final m = clipWithSidecar().toMap();
        expect(m.containsKey('sourceRoiSidecarPath'), isFalse);
        final clone = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
        expect(clone, isNotNull);
        expect(clone!.sourceRoiSidecarPath, isNull);
      },
    );

    test(
      'SR-8  empty string sourceRoiSidecarPath in fromMap() returns null',
      () {
        final m = clipWithSidecar().toMap();
        m['sourceRoiSidecarPath'] = '';
        final clone = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m));
        expect(clone, isNotNull);
        expect(clone!.sourceRoiSidecarPath, isNull);
      },
    );

    test(
      'SR-9  non-String sourceRoiSidecarPath produces null without failing deserialization',
      () {
        // Integer
        final m1 = clipWithSidecar().toMap()..['sourceRoiSidecarPath'] = 12345;
        final clone1 = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m1));
        expect(clone1, isNotNull);
        expect(clone1!.sourceRoiSidecarPath, isNull);

        // Boolean
        final m2 = clipWithSidecar().toMap()..['sourceRoiSidecarPath'] = true;
        final clone2 = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m2));
        expect(clone2, isNotNull);
        expect(clone2!.sourceRoiSidecarPath, isNull);

        // Map
        final m3 = clipWithSidecar().toMap()
          ..['sourceRoiSidecarPath'] = {'path': '/some/path'};
        final clone3 = VGClipDescriptor.fromMap(Map<Object?, Object?>.from(m3));
        expect(clone3, isNotNull);
        expect(clone3!.sourceRoiSidecarPath, isNull);
      },
    );

    test(
      'SR-10 copyWith preserves sourceRoiSidecarPath when not overridden',
      () {
        final clip = clipWithSidecar(
          sourceRoiSidecarPath: '/original/sidecar.roi.json',
        );
        final copy = clip.copyWith(id: 'clip-copy');
        expect(copy.sourceRoiSidecarPath, '/original/sidecar.roi.json');
      },
    );

    test('SR-11 copyWith can update sourceRoiSidecarPath', () {
      final clip = clipWithSidecar(sourceRoiSidecarPath: '/old/path.roi.json');
      final copy = clip.copyWith(sourceRoiSidecarPath: '/new/path.roi.json');
      expect(copy.sourceRoiSidecarPath, '/new/path.roi.json');
    });

    test(
      'SR-12 copyWith can clear sourceRoiSidecarPath to null via sentinel',
      () {
        final clip = clipWithSidecar(
          sourceRoiSidecarPath: '/custom/path.roi.json',
        );
        final cleared = clip.copyWith(sourceRoiSidecarPath: null);
        expect(cleared.sourceRoiSidecarPath, isNull);
      },
    );

    test('SR-13 equality and hashCode include sourceRoiSidecarPath', () {
      final a = clipWithSidecar(
        sourceRoiSidecarPath: '/path/to/sidecar.roi.json',
      );
      final b = clipWithSidecar(
        sourceRoiSidecarPath: '/path/to/sidecar.roi.json',
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('SR-14 equality differs when sourceRoiSidecarPath differs', () {
      final a = clipWithSidecar(sourceRoiSidecarPath: '/path/a.roi.json');
      final b = clipWithSidecar(sourceRoiSidecarPath: '/path/b.roi.json');
      final c = clipWithSidecar(sourceRoiSidecarPath: null);
      expect(a == b, isFalse);
      expect(a == c, isFalse);
      expect(b == c, isFalse);
    });
  });
}

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

// ─── Phase 7.16: VGStillImageFitMode and cropRect ────────────────────────────
// Added by Phase 7.16 Implementer.
// Tests IK-8 through IK-22 and CV-1 through CV-12 above cover:
//   IK-8   Default fitMode is fit.
//   IK-9   Default cropRect is null. Convenience accessors return null.
//   IK-10  fitMode=fill serialises to "fill" key.
//   IK-11  fitMode=fit (default) is omitted from toMap().
//   IK-12  fitMode fill round-trips via fromMap().
//   IK-13  Missing fitMode key in fromMap() defaults to fit.
//   IK-14  Unknown fitMode string in fromMap() defaults to fit.
//   IK-15  cropRect round-trip via fromMap() with correct values.
//   IK-16  Null cropRect is omitted from toMap().
//   IK-17  copyWith preserves fitMode and cropRect when not overridden.
//   IK-18  copyWith can update fitMode.
//   IK-19  copyWith can clear cropRect to null using sentinel.
//   IK-20  Equality includes fitMode and cropRect.
//   IK-21  Equality differs when fitMode differs.
//   IK-22  Equality differs when cropRect differs.
//   CV-1   cropRect length != 4 (3 elements) rejected by fromMap().
//   CV-2   cropRect length != 4 (5 elements) rejected by fromMap().
//   CV-3   cropRect x < 0 rejected by fromMap().
//   CV-4   cropRect width == 0 rejected by fromMap().
//   CV-5   cropRect height == 0 rejected by fromMap().
//   CV-6   cropRect x + width > 1.0 rejected by fromMap().
//   CV-7   cropRect y + height > 1.0 rejected by fromMap().
//   CV-8   cropRect value > 1.0 rejected by fromMap().
//   CV-9   Valid full-frame cropRect [0,0,1,1] accepted.
//   CV-10  VGStillImageFitMode.fromValue("fill") resolves to fill.
//   CV-11  VGStillImageFitMode.fromValue("fit") resolves to fit.
//   CV-12  VGStillImageFitMode.fromValue unknown string resolves to fit.

// ─── Phase 7.19B: isReversed and VGEditorDraft.reverseClip ──────────────────
// Added by Phase 7.19B Implementer.
// Tests FF-1 through FF-12 and FC-1 through FC-8 above cover:
//   FF-1   Default freezePTS is null.
//   FF-2   Non-null freezePTS is stored correctly.
//   FF-3   Zero freezePTS is valid (non-negative boundary).
//   FF-4   Non-null freezePTS serialises to toMap().
//   FF-5   Null freezePTS is omitted from toMap().
//   FF-6   freezePTS round-trips via fromMap().
//   FF-7   Absent freezePTS key in fromMap() returns null.
//   FF-8   Negative freezePTS rejected by fromMap().
//   FF-9   copyWith preserves freezePTS when not overridden.
//   FF-10  copyWith can clear freezePTS to null via sentinel.
//   FF-11  Equality includes freezePTS.
//   FF-12  Equality differs when freezePTS differs.
//   FC-1   freezeClip returns 3-clip draft.
//   FC-2   Left clip retains original ID and trimEnd.
//   FC-3   Freeze clip has correct ID, freezePTS, hold duration, speed.
//   FC-4   Right clip has deterministic ID and trimStart.
//   FC-5   Unknown clipId throws ArgumentError.
//   FC-6   splitSeconds outside trim window throws ArgumentError.
//   FC-7   Non-positive duration throws ArgumentError.
//   FC-8   Non-video clip throws ArgumentError.
//   RV-1   isReversed defaults to false.
//   RV-2   isReversed=true is stored correctly.
//   RV-3   false isReversed is omitted from toMap() (wire-minimal).
//   RV-4   true isReversed serialises to toMap() as true.
//   RV-5   isReversed round-trips via fromMap() when true.
//   RV-6   Absent isReversed key in fromMap() defaults to false.
//   RV-7   copyWith preserves isReversed when not overridden.
//   RV-8   copyWith can set isReversed to true.
//   RV-9   Equality includes isReversed.
//   RV-10  Equality differs when isReversed differs.
