// vg_livestream_overlay_item_test.dart
// Vanguard Media Engine — Slice G1-A
//
// Unit tests for VGLivestreamOverlayKind, VGLivestreamOverlayCanvas,
// VGLivestreamOverlayItem, and VGFilterSpecs.overlay(...). Pure Dart — no
// platform channels, no native code.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_filter_spec.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart'
    show
        VGLivestreamOverlayItem,
        VGLivestreamOverlayKind,
        VGLivestreamOverlayCanvas;

VGLivestreamOverlayItem _textItem({
  String id = 't1',
  double x = 0.05,
  double y = 0.80,
  double w = 0.40,
  double h = 0.08,
  double opacity = 1.0,
  int z = 0,
  String text = 'LIVE',
}) => VGLivestreamOverlayItem(
  id: id,
  kind: VGLivestreamOverlayKind.text,
  x: x,
  y: y,
  w: w,
  h: h,
  opacity: opacity,
  z: z,
  text: text,
);

VGLivestreamOverlayItem _stickerItem({
  String id = 's1',
  double x = 0.60,
  double y = 0.05,
  double w = 0.30,
  double h = 0.30,
  double opacity = 1.0,
  int z = 0,
  String assetPath = '/data/stickers/fire.png',
}) => VGLivestreamOverlayItem(
  id: id,
  kind: VGLivestreamOverlayKind.sticker,
  x: x,
  y: y,
  w: w,
  h: h,
  opacity: opacity,
  z: z,
  assetPath: assetPath,
);

void main() {
  group('VGLivestreamOverlayKind.fromValue', () {
    test('resolves known wire values', () {
      expect(
        VGLivestreamOverlayKind.fromValue('text'),
        VGLivestreamOverlayKind.text,
      );
      expect(
        VGLivestreamOverlayKind.fromValue('sticker'),
        VGLivestreamOverlayKind.sticker,
      );
    });

    test('throws ArgumentError on an unknown value — no silent fallback', () {
      expect(
        () => VGLivestreamOverlayKind.fromValue('emoji'),
        throwsArgumentError,
      );
      expect(() => VGLivestreamOverlayKind.fromValue(''), throwsArgumentError);
    });

    test('value round-trips through the enum', () {
      for (final kind in VGLivestreamOverlayKind.values) {
        expect(VGLivestreamOverlayKind.fromValue(kind.value), kind);
      }
    });
  });

  group('VGLivestreamOverlayCanvas — pinned 720×1280', () {
    test('dimensions are pinned constants', () {
      expect(VGLivestreamOverlayCanvas.width, 720);
      expect(VGLivestreamOverlayCanvas.height, 1280);
    });

    test('toJson produces the exact wire shape', () {
      expect(
        VGLivestreamOverlayCanvas.instance.toJson(),
        equals(const {'width': 720, 'height': 1280}),
      );
    });
  });

  group('VGLivestreamOverlayItem — construction and bounds', () {
    test('a valid text item constructs without throwing', () {
      final item = _textItem();
      expect(item.id, 't1');
      expect(item.kind, VGLivestreamOverlayKind.text);
      expect(item.text, 'LIVE');
      expect(item.assetPath, isNull);
    });

    test('a valid sticker item constructs without throwing', () {
      final item = _stickerItem();
      expect(item.id, 's1');
      expect(item.kind, VGLivestreamOverlayKind.sticker);
      expect(item.assetPath, '/data/stickers/fire.png');
      expect(item.text, isNull);
    });

    test('empty id throws ArgumentError', () {
      expect(() => _textItem(id: ''), throwsArgumentError);
    });

    test('x/y accept the closed bounds [0.0, 1.0]', () {
      expect(() => _textItem(x: 0.0, y: 0.0), returnsNormally);
      expect(() => _textItem(x: 1.0, y: 1.0), returnsNormally);
    });

    test('x/y reject values outside [0.0, 1.0]', () {
      expect(() => _textItem(x: -0.0001), throwsArgumentError);
      expect(() => _textItem(x: 1.0001), throwsArgumentError);
      expect(() => _textItem(y: -0.0001), throwsArgumentError);
      expect(() => _textItem(y: 1.0001), throwsArgumentError);
    });

    test('w/h reject zero and negative values — must be > 0', () {
      expect(() => _textItem(w: 0.0), throwsArgumentError);
      expect(() => _textItem(w: -0.1), throwsArgumentError);
      expect(() => _textItem(h: 0.0), throwsArgumentError);
      expect(() => _textItem(h: -0.1), throwsArgumentError);
    });

    test('w/h accept the closed upper bound 1.0 but reject above it', () {
      expect(() => _textItem(w: 1.0, h: 1.0), returnsNormally);
      expect(() => _textItem(w: 1.0001), throwsArgumentError);
      expect(() => _textItem(h: 1.0001), throwsArgumentError);
    });

    test('opacity accepts the closed bounds [0.0, 1.0]', () {
      expect(() => _textItem(opacity: 0.0), returnsNormally);
      expect(() => _textItem(opacity: 1.0), returnsNormally);
    });

    test('opacity rejects values outside [0.0, 1.0]', () {
      expect(() => _textItem(opacity: -0.0001), throwsArgumentError);
      expect(() => _textItem(opacity: 1.0001), throwsArgumentError);
    });
  });

  group('VGLivestreamOverlayItem — text overlay validation', () {
    test('null text throws ArgumentError', () {
      expect(
        () => VGLivestreamOverlayItem(
          id: 't1',
          kind: VGLivestreamOverlayKind.text,
          x: 0,
          y: 0,
          w: 0.5,
          h: 0.1,
        ),
        throwsArgumentError,
      );
    });

    test('empty text throws ArgumentError', () {
      expect(() => _textItem(text: ''), throwsArgumentError);
    });

    test('text at exactly 120 characters is accepted', () {
      final text = 'a' * 120;
      expect(() => _textItem(text: text), returnsNormally);
      expect(_textItem(text: text).text!.length, 120);
    });

    test('text longer than 120 characters throws ArgumentError', () {
      final text = 'a' * 121;
      expect(() => _textItem(text: text), throwsArgumentError);
    });

    test('a non-null assetPath on a text overlay throws ArgumentError', () {
      expect(
        () => VGLivestreamOverlayItem(
          id: 't1',
          kind: VGLivestreamOverlayKind.text,
          x: 0,
          y: 0,
          w: 0.5,
          h: 0.1,
          text: 'LIVE',
          assetPath: '/data/stickers/fire.png',
        ),
        throwsArgumentError,
      );
    });
  });

  group('VGLivestreamOverlayItem — sticker overlay validation', () {
    test('null assetPath throws ArgumentError', () {
      expect(
        () => VGLivestreamOverlayItem(
          id: 's1',
          kind: VGLivestreamOverlayKind.sticker,
          x: 0,
          y: 0,
          w: 0.3,
          h: 0.3,
        ),
        throwsArgumentError,
      );
    });

    test('blank assetPath throws ArgumentError', () {
      expect(() => _stickerItem(assetPath: '   '), throwsArgumentError);
    });

    test('a non-null text on a sticker overlay throws ArgumentError', () {
      expect(
        () => VGLivestreamOverlayItem(
          id: 's1',
          kind: VGLivestreamOverlayKind.sticker,
          x: 0,
          y: 0,
          w: 0.3,
          h: 0.3,
          text: 'oops',
          assetPath: '/data/stickers/fire.png',
        ),
        throwsArgumentError,
      );
    });

    test('a non-absolute path (no leading "/") throws ArgumentError', () {
      expect(
        () => _stickerItem(assetPath: 'stickers/fire.png'),
        throwsArgumentError,
      );
    });

    test('remote/URI paths are rejected regardless of scheme', () {
      for (final path in <String>[
        'http://example.com/fire.png',
        'https://example.com/fire.png',
        'content://media/external/images/1',
        'file:///data/stickers/fire.png',
        'ftp://example.com/fire.png',
      ]) {
        expect(
          () => _stickerItem(assetPath: path),
          throwsArgumentError,
          reason: '$path must be rejected as a remote/URI path',
        );
      }
    });

    test('accepts .png, .jpg, .jpeg case-insensitively', () {
      for (final path in <String>[
        '/data/stickers/fire.png',
        '/data/stickers/fire.PNG',
        '/data/stickers/fire.jpg',
        '/data/stickers/fire.JPG',
        '/data/stickers/fire.jpeg',
        '/data/stickers/fire.JPEG',
      ]) {
        expect(
          () => _stickerItem(assetPath: path),
          returnsNormally,
          reason: '$path must be accepted',
        );
      }
    });

    test('rejects any other extension', () {
      for (final path in <String>[
        '/data/stickers/fire.gif',
        '/data/stickers/fire.webp',
        '/data/stickers/fire',
        '/data/stickers/fire.png.exe',
      ]) {
        expect(
          () => _stickerItem(assetPath: path),
          throwsArgumentError,
          reason: '$path must be rejected',
        );
      }
    });
  });

  group('VGLivestreamOverlayItem — z (paint order)', () {
    test('defaults to 0 when omitted from the constructor', () {
      expect(_textItem().z, 0);
    });

    test('a custom z serializes into toJson', () {
      final json = _textItem(z: 42).toJson();
      expect(json['z'], 42);
    });

    test('fromMap defaults missing z to 0', () {
      final parsed = VGLivestreamOverlayItem.fromMap(<String, Object?>{
        'id': 't1',
        'kind': 'text',
        'x': 0.0,
        'y': 0.0,
        'w': 0.5,
        'h': 0.1,
        'text': 'LIVE',
        // 'z' intentionally absent
      });
      expect(parsed.z, 0);
    });

    test('negative or too-large z throws ArgumentError', () {
      expect(() => _textItem(z: -1), throwsArgumentError);
      expect(() => _textItem(z: 1025), throwsArgumentError);
      expect(() => _textItem(z: 0), returnsNormally);
      expect(() => _textItem(z: 1024), returnsNormally);
    });

    test('a wrong-type z in fromMap throws ArgumentError', () {
      expect(
        () => VGLivestreamOverlayItem.fromMap(<String, Object?>{
          'id': 't1',
          'kind': 'text',
          'x': 0.0,
          'y': 0.0,
          'w': 0.5,
          'h': 0.1,
          'text': 'LIVE',
          'z': 'not a number',
        }),
        throwsArgumentError,
      );
    });
  });

  group('VGLivestreamOverlayItem — serialization (toJson)', () {
    test('a text item serializes with text present and assetPath omitted', () {
      final json = _textItem().toJson();
      expect(json['id'], 't1');
      expect(json['kind'], 'text');
      expect(json['x'], 0.05);
      expect(json['y'], 0.80);
      expect(json['w'], 0.40);
      expect(json['h'], 0.08);
      expect(json['opacity'], 1.0);
      expect(json['z'], 0);
      expect(json['text'], 'LIVE');
      expect(json.containsKey('assetPath'), isFalse);
    });

    test(
      'a sticker item serializes with assetPath present and text omitted',
      () {
        final json = _stickerItem().toJson();
        expect(json['kind'], 'sticker');
        expect(json['assetPath'], '/data/stickers/fire.png');
        expect(json.containsKey('text'), isFalse);
      },
    );
  });

  group('VGLivestreamOverlayItem.fromMap', () {
    test('round-trips a text item through toJson/fromMap', () {
      final original = _textItem();
      final parsed = VGLivestreamOverlayItem.fromMap(original.toJson());
      expect(parsed, equals(original));
    });

    test('round-trips a sticker item through toJson/fromMap', () {
      final original = _stickerItem();
      final parsed = VGLivestreamOverlayItem.fromMap(original.toJson());
      expect(parsed, equals(original));
    });

    test('an unrecognized kind throws ArgumentError (no silent fallback)', () {
      expect(
        () => VGLivestreamOverlayItem.fromMap(<String, Object?>{
          'id': 't1',
          'kind': 'emoji',
          'x': 0.0,
          'y': 0.0,
          'w': 0.5,
          'h': 0.1,
        }),
        throwsArgumentError,
      );
    });

    test('a missing required field throws ArgumentError', () {
      expect(
        () => VGLivestreamOverlayItem.fromMap(<String, Object?>{
          'id': 't1',
          'kind': 'text',
          'x': 0.0,
          'y': 0.0,
          'w': 0.5,
          // 'h' missing
        }),
        throwsArgumentError,
      );
    });

    test('a wrong-type field throws ArgumentError', () {
      expect(
        () => VGLivestreamOverlayItem.fromMap(<String, Object?>{
          'id': 42, // must be a String
          'kind': 'text',
          'x': 0.0,
          'y': 0.0,
          'w': 0.5,
          'h': 0.1,
          'text': 'LIVE',
        }),
        throwsArgumentError,
      );
    });

    test('an invalid parsed item (e.g. text too long) still throws', () {
      expect(
        () => VGLivestreamOverlayItem.fromMap(<String, Object?>{
          'id': 't1',
          'kind': 'text',
          'x': 0.0,
          'y': 0.0,
          'w': 0.5,
          'h': 0.1,
          'text': 'a' * 121,
        }),
        throwsArgumentError,
      );
    });

    test('opacity defaults to 1.0 when absent from the map', () {
      final parsed = VGLivestreamOverlayItem.fromMap(<String, Object?>{
        'id': 't1',
        'kind': 'text',
        'x': 0.0,
        'y': 0.0,
        'w': 0.5,
        'h': 0.1,
        'text': 'LIVE',
      });
      expect(parsed.opacity, 1.0);
    });
  });

  group('VGFilterSpecs.overlay', () {
    test('produces type "overlay" and the pinned canvas', () {
      final spec = VGFilterSpecs.overlay(items: [_textItem()]);
      expect(spec.type, 'overlay');
      expect(
        spec.parameters['canvas'],
        equals(const {'width': 720, 'height': 1280}),
      );
    });

    test('enabled is true only when enabled=true AND items is non-empty', () {
      expect(VGFilterSpecs.overlay(items: [_textItem()]).enabled, isTrue);
      expect(
        VGFilterSpecs.overlay(items: [_textItem()], enabled: false).enabled,
        isFalse,
      );
      expect(VGFilterSpecs.overlay(items: const []).enabled, isFalse);
      expect(
        VGFilterSpecs.overlay(items: const [], enabled: true).enabled,
        isFalse,
      );
    });

    test('parameters.items is the full serialized item list, in order', () {
      final text = _textItem();
      final sticker = _stickerItem();
      final spec = VGFilterSpecs.overlay(items: [text, sticker]);
      final items = spec.parameters['items'] as List<Object?>;
      expect(items, hasLength(2));
      expect(items[0], equals(text.toJson()));
      expect(items[1], equals(sticker.toJson()));
    });

    test('an empty item list still produces canvas + empty items', () {
      final spec = VGFilterSpecs.overlay(items: const []);
      expect(spec.parameters['items'], isEmpty);
      expect(
        spec.parameters['canvas'],
        equals(const {'width': 720, 'height': 1280}),
      );
    });

    test('exactly 8 items is accepted', () {
      final items = List.generate(8, (i) => _textItem(id: 't$i'));
      expect(() => VGFilterSpecs.overlay(items: items), returnsNormally);
    });

    test('more than 8 items throws ArgumentError', () {
      final items = List.generate(9, (i) => _textItem(id: 't$i'));
      expect(() => VGFilterSpecs.overlay(items: items), throwsArgumentError);
    });

    test('assertValid() does not throw for an overlay spec — "overlay" is '
        'a recognized filter type', () {
      final spec = VGFilterSpecs.overlay(items: [_textItem()]);
      expect(() => spec.assertValid(), returnsNormally);
    });
  });
}
