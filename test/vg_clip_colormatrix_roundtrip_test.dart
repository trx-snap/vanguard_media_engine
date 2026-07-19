import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_clip_descriptor.dart';

void main() {
  final identity = List<double>.generate(20, (i) => i == 0 || i == 6 || i == 12 || i == 18 ? 1.0 : 0.0);
  final sepia = <double>[
    0.393, 0.769, 0.189, 0, 0,
    0.349, 0.686, 0.168, 0, 0,
    0.272, 0.534, 0.131, 0, 0,
    0,     0,     0,     1, 0,
  ];

  VGClipDescriptor makeClip({List<double>? colorMatrix}) => VGClipDescriptor(
    id: 'test-clip',
    sourcePath: '/tmp/test.mp4',
    mediaKind: VGMediaKind.video,
    startTimeSeconds: 0.0,
    durationSeconds: 10.0,
    trimStartSeconds: 0.0,
    trimEndSeconds: 10.0,
    colorMatrix: colorMatrix,
  );

  test('colorMatrix null — omitted from toMap()', () {
    final clip = makeClip(colorMatrix: null);
    final map = clip.toMap();
    expect(map.containsKey('colorMatrix'), isFalse);
  });

  test('colorMatrix non-null — serialised and round-tripped', () {
    final clip = makeClip(colorMatrix: sepia);
    final map = clip.toMap();
    expect(map.containsKey('colorMatrix'), isTrue);
    expect((map['colorMatrix'] as List).length, equals(20));

    final restored = VGClipDescriptor.fromMap(map);
    expect(restored, isNotNull);
    expect(restored!.colorMatrix, isNotNull);
    expect(restored.colorMatrix!.length, equals(20));
    for (var i = 0; i < 20; i++) {
      expect(restored.colorMatrix![i], closeTo(sepia[i], 1e-9));
    }
  });

  test('colorMatrix identity — round-trips', () {
    final clip = makeClip(colorMatrix: identity);
    final restored = VGClipDescriptor.fromMap(clip.toMap());
    expect(restored, isNotNull);
    expect(restored!.colorMatrix, isNotNull);
  });

  test('fromMap rejects colorMatrix with wrong count', () {
    final clip = makeClip(colorMatrix: sepia);
    final map = Map<Object?, Object?>.from(clip.toMap());
    map['colorMatrix'] = <double>[1.0, 2.0]; // wrong length
    expect(VGClipDescriptor.fromMap(map), isNull);
  });

  test('fromMap rejects colorMatrix with non-numeric elements', () {
    final clip = makeClip(colorMatrix: sepia);
    final map = Map<Object?, Object?>.from(clip.toMap());
    map['colorMatrix'] = List.filled(20, 'not-a-number');
    expect(VGClipDescriptor.fromMap(map), isNull);
  });

  test('colorMatrix absent — fromMap produces null colorMatrix', () {
    final clip = makeClip(colorMatrix: null);
    final restored = VGClipDescriptor.fromMap(clip.toMap());
    expect(restored, isNotNull);
    expect(restored!.colorMatrix, isNull);
  });

  test('copyWith colorMatrix — replaces field', () {
    final original = makeClip(colorMatrix: identity);
    final updated = original.copyWith(colorMatrix: sepia);
    expect(updated.colorMatrix, equals(sepia));
  });

  test('copyWith without colorMatrix — preserves existing', () {
    final original = makeClip(colorMatrix: sepia);
    final updated = original.copyWith(id: 'other');
    expect(updated.colorMatrix, equals(sepia));
  });

  test('copyWith colorMatrix: null — clears colorMatrix', () {
    final original = makeClip(colorMatrix: sepia);
    final updated = original.copyWith(colorMatrix: null);
    expect(updated.colorMatrix, isNull);
  });

  test('equality: clips differ only in colorMatrix are not equal', () {
    final a = makeClip(colorMatrix: sepia);
    final b = makeClip(colorMatrix: null);
    expect(a == b, isFalse);
    expect(a == a.copyWith(), isTrue);
  });
}
