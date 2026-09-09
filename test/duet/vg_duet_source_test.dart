// Copyright 2026, Connects. All rights reserved.
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/src/duet/vg_duet_source.dart';

void main() {
  group('VGDuetSource.localFile', () {
    test('accepts valid .mp4 path', () {
      final src = VGDuetSource.localFile('/tmp/clip.mp4');
      expect(src.filePath, '/tmp/clip.mp4');
      expect(src.extension, 'mp4');
      expect(src.fileName, 'clip.mp4');
    });

    test('accepts valid .mov path', () {
      final src = VGDuetSource.localFile('/tmp/clip.mov');
      expect(src.extension, 'mov');
    });

    test('accepts uppercase extension .MP4 (case-insensitive)', () {
      final src = VGDuetSource.localFile('/tmp/clip.MP4');
      expect(src.extension, 'mp4');
    });

    test('accepts uppercase extension .MOV', () {
      final src = VGDuetSource.localFile('/tmp/clip.MOV');
      expect(src.extension, 'mov');
    });

    test('trims leading/trailing whitespace from path', () {
      final src = VGDuetSource.localFile('  /tmp/clip.mp4  ');
      expect(src.filePath, '/tmp/clip.mp4');
    });

    test('throws ArgumentError for empty path', () {
      expect(() => VGDuetSource.localFile(''), throwsArgumentError);
    });

    test('throws ArgumentError for blank path', () {
      expect(() => VGDuetSource.localFile('   '), throwsArgumentError);
    });

    test('throws ArgumentError for .avi extension', () {
      expect(
        () => VGDuetSource.localFile('/tmp/clip.avi'),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError for .mkv extension', () {
      expect(
        () => VGDuetSource.localFile('/tmp/clip.mkv'),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError for path without extension', () {
      expect(() => VGDuetSource.localFile('/tmp/clip'), throwsArgumentError);
    });

    test('does not require file to exist (no dart:io check)', () {
      // This path does not exist on disk; localFile must not throw.
      expect(
        () => VGDuetSource.localFile('/non_existent/path/clip.mp4'),
        returnsNormally,
      );
    });

    test('value equality', () {
      final a = VGDuetSource.localFile('/tmp/clip.mp4');
      final b = VGDuetSource.localFile('/tmp/clip.mp4');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('inequality for different paths', () {
      final a = VGDuetSource.localFile('/tmp/a.mp4');
      final b = VGDuetSource.localFile('/tmp/b.mp4');
      expect(a, isNot(equals(b)));
    });

    test('toMap / fromMap round-trip', () {
      final src = VGDuetSource.localFile('/tmp/clip.mp4');
      final map = src.toMap();
      expect(map['filePath'], '/tmp/clip.mp4');
      final restored = VGDuetSource.fromMap(map);
      expect(restored, equals(src));
    });

    test('fromMap throws ArgumentError for missing filePath', () {
      expect(
        () => VGDuetSource.fromMap({'filePath': 123}),
        throwsArgumentError,
      );
    });

    test('fromMap throws for invalid extension', () {
      expect(
        () => VGDuetSource.fromMap({'filePath': '/tmp/clip.avi'}),
        throwsArgumentError,
      );
    });

    test('toString contains filePath', () {
      final src = VGDuetSource.localFile('/tmp/clip.mp4');
      expect(src.toString(), contains('/tmp/clip.mp4'));
    });
  });
}
