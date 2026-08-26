// vg_editor_export_result_test.dart
// Vanguard Media Engine — Unit D VGEditorExportResult tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGEditorExportResult', () {
    test('absent exportRoiSidecarPath remains backward-compatible', () {
      final map = <String, dynamic>{
        'success': true,
        'path': '/tmp/out.mp4',
        'durationSeconds': 1.25,
      };
      final result = VGEditorExportResult.fromMap(map);

      expect(result, isNotNull);
      expect(result!.path, equals('/tmp/out.mp4'));
      expect(result.durationSeconds, equals(1.25));
      expect(result.exportRoiSidecarPath, isNull);

      final exportedMap = result.toMap();
      expect(exportedMap.containsKey('exportRoiSidecarPath'), isFalse);
      expect(exportedMap['path'], equals('/tmp/out.mp4'));
      expect(exportedMap['durationSeconds'], equals(1.25));
    });

    test('present exportRoiSidecarPath populates field and toMap', () {
      final map = <String, dynamic>{
        'success': true,
        'path': '/tmp/out.mp4',
        'durationSeconds': 1.25,
        'width': 1920,
        'height': 1080,
        'fps': 30,
        'exportRoiSidecarPath': '/tmp/out.roi.json',
      };
      final result = VGEditorExportResult.fromMap(map);

      expect(result, isNotNull);
      expect(result!.path, equals('/tmp/out.mp4'));
      expect(result.durationSeconds, equals(1.25));
      expect(result.width, equals(1920));
      expect(result.height, equals(1080));
      expect(result.fps, equals(30));
      expect(result.exportRoiSidecarPath, equals('/tmp/out.roi.json'));

      final exportedMap = result.toMap();
      expect(exportedMap.containsKey('exportRoiSidecarPath'), isTrue);
      expect(exportedMap['exportRoiSidecarPath'], equals('/tmp/out.roi.json'));
      expect(exportedMap['path'], equals('/tmp/out.mp4'));
      expect(exportedMap['durationSeconds'], equals(1.25));
      expect(exportedMap['width'], equals(1920));
      expect(exportedMap['height'], equals(1080));
      expect(exportedMap['fps'], equals(30));
    });

    test('equality and hashCode include exportRoiSidecarPath', () {
      const baseResult = VGEditorExportResult(
        path: '/tmp/out.mp4',
        durationSeconds: 1.25,
        width: 1920,
        height: 1080,
        fps: 30,
        exportRoiSidecarPath: '/tmp/out.roi.json',
      );
      const identicalResult = VGEditorExportResult(
        path: '/tmp/out.mp4',
        durationSeconds: 1.25,
        width: 1920,
        height: 1080,
        fps: 30,
        exportRoiSidecarPath: '/tmp/out.roi.json',
      );
      const nullSidecarResult = VGEditorExportResult(
        path: '/tmp/out.mp4',
        durationSeconds: 1.25,
        width: 1920,
        height: 1080,
        fps: 30,
        exportRoiSidecarPath: null,
      );
      const differentSidecarResult = VGEditorExportResult(
        path: '/tmp/out.mp4',
        durationSeconds: 1.25,
        width: 1920,
        height: 1080,
        fps: 30,
        exportRoiSidecarPath: '/tmp/other.roi.json',
      );

      // Reflexive and value equality
      expect(baseResult, equals(identicalResult));
      expect(baseResult.hashCode, equals(identicalResult.hashCode));

      // Differing only in exportRoiSidecarPath (present vs null)
      expect(baseResult, isNot(equals(nullSidecarResult)));
      expect(baseResult.hashCode, isNot(equals(nullSidecarResult.hashCode)));

      // Differing only in exportRoiSidecarPath (different string paths)
      expect(baseResult, isNot(equals(differentSidecarResult)));
      expect(
        baseResult.hashCode,
        isNot(equals(differentSidecarResult.hashCode)),
      );
    });

    test('explicit success: false returns null', () {
      final map = <String, dynamic>{
        'success': false,
        'path': '/tmp/out.mp4',
        'durationSeconds': 1.25,
        'exportRoiSidecarPath': '/tmp/out.roi.json',
      };
      final result = VGEditorExportResult.fromMap(map);

      expect(result, isNull);
    });

    test('missing required fields return null', () {
      expect(
        VGEditorExportResult.fromMap({
          'success': true,
          'durationSeconds': 1.25,
          'exportRoiSidecarPath': '/tmp/out.roi.json',
        }),
        isNull,
      );

      expect(
        VGEditorExportResult.fromMap({
          'success': true,
          'path': '/tmp/out.mp4',
          'exportRoiSidecarPath': '/tmp/out.roi.json',
        }),
        isNull,
      );

      expect(
        VGEditorExportResult.fromMap({
          'success': true,
          'path': '',
          'durationSeconds': 1.25,
          'exportRoiSidecarPath': '/tmp/out.roi.json',
        }),
        isNull,
      );
    });
  });
}
