// vg_camera2_logical_physical_topology_test.dart
// vanguard_media_engine — Phase 3-Unit R: Android Camera2 Logical/Physical
// Sensor Topology Physical Proof Foundation unit & contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

/// Local topology evaluation summary used to validate Camera2 logical and
/// physical sensor relationships without modifying production Dart contracts.
class _CameraTopologySummary {
  const _CameraTopologySummary({
    required this.totalCameraCount,
    required this.logicalCameraCount,
    required this.nonLogicalCameraCount,
    required this.logicalCameraIds,
    required this.physicalChildIds,
    required this.uniquePhysicalChildIds,
    required this.publicCameraIds,
    required this.hasLogicalCamera,
    required this.isValidTopology,
    required this.issues,
  });

  final int totalCameraCount;
  final int logicalCameraCount;
  final int nonLogicalCameraCount;
  final List<String> logicalCameraIds;
  final List<String> physicalChildIds;
  final Set<String> uniquePhysicalChildIds;
  final List<String> publicCameraIds;
  final bool hasLogicalCamera;
  final bool isValidTopology;
  final List<String> issues;

  Map<String, Object?> toMap() => {
    'totalCameraCount': totalCameraCount,
    'logicalCameraCount': logicalCameraCount,
    'nonLogicalCameraCount': nonLogicalCameraCount,
    'logicalCameraIds': logicalCameraIds,
    'physicalChildIds': physicalChildIds,
    'uniquePhysicalChildIds': uniquePhysicalChildIds.toList(),
    'publicCameraIds': publicCameraIds,
    'hasLogicalCamera': hasLogicalCamera,
    'isValidTopology': isValidTopology,
    'issues': issues,
  };
}

/// Local helper that evaluates Camera2 sensor topology rules on a probe report.
_CameraTopologySummary _analyzeTopology(
  VGCameraHardwareCapabilityReport report,
) {
  final issues = <String>[];
  final publicCameraIds = <String>[];
  final seenPublicIds = <String>{};

  for (final camera in report.cameras) {
    if (camera.cameraId.isEmpty) {
      issues.add('empty_public_camera_id');
    } else if (!seenPublicIds.add(camera.cameraId)) {
      issues.add('duplicate_public_camera_id:${camera.cameraId}');
    }
    publicCameraIds.add(camera.cameraId);

    // Coherence between boolean flag and capabilities token list.
    final hasLogicalCap = camera.capabilities.contains('LOGICAL_MULTI_CAMERA');
    if (camera.isLogicalMultiCamera != hasLogicalCap) {
      issues.add(
        'logical_flag_capability_mismatch:${camera.cameraId}:'
        'isLogical=${camera.isLogicalMultiCamera},hasCap=$hasLogicalCap',
      );
    }

    if (camera.isLogicalMultiCamera) {
      if (camera.physicalCameraIds.isEmpty) {
        issues.add('empty_physical_camera_ids:${camera.cameraId}');
      }
      final seenPhysical = <String>{};
      for (final physId in camera.physicalCameraIds) {
        if (physId.isEmpty) {
          issues.add('empty_physical_id_entry:${camera.cameraId}');
        } else if (!seenPhysical.add(physId)) {
          issues.add('duplicate_physical_camera_id:${camera.cameraId}:$physId');
        }
      }
      if (camera.physicalCameraIds.contains(camera.cameraId)) {
        issues.add('parent_id_in_physical_camera_ids:${camera.cameraId}');
      }
    }
  }

  // Concurrent camera ID sets must contain only public camera IDs.
  final publicIdSet = seenPublicIds;
  for (final set in report.concurrentCameraIdSets) {
    for (final id in set) {
      if (!publicIdSet.contains(id)) {
        issues.add('concurrent_set_contains_non_public_camera_id:$id');
      }
    }
  }

  final logicalCameras = report.cameras
      .where((c) => c.isLogicalMultiCamera)
      .toList();
  final nonLogicalCameras = report.cameras
      .where((c) => !c.isLogicalMultiCamera)
      .toList();
  final allPhysicalChildIds = <String>[];
  for (final c in logicalCameras) {
    allPhysicalChildIds.addAll(c.physicalCameraIds);
  }

  return _CameraTopologySummary(
    totalCameraCount: report.cameras.length,
    logicalCameraCount: logicalCameras.length,
    nonLogicalCameraCount: nonLogicalCameras.length,
    logicalCameraIds: logicalCameras.map((c) => c.cameraId).toList(),
    physicalChildIds: allPhysicalChildIds,
    uniquePhysicalChildIds: allPhysicalChildIds.toSet(),
    publicCameraIds: publicCameraIds,
    hasLogicalCamera: logicalCameras.isNotEmpty,
    isValidTopology: issues.isEmpty,
    issues: issues,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const defaultChannel = MethodChannel('vanguard_media_engine');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGCamera2 Logical/Physical Sensor Topology Tests', () {
    // ─────────────────────────────────────────────────────────────────────────
    // 1. Fixture with Logical Multi-Camera + Physical Children
    // ─────────────────────────────────────────────────────────────────────────
    group('Logical multi-camera fixture', () {
      final multiCameraReportMap = <String, Object?>{
        'success': true,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'thermalStatus': 0,
        'thermalStatusName': 'none',
        'cameraCount': 4,
        'supportsConcurrentCamera': true,
        'concurrentCameraIdSets': [
          ['0', '1'],
        ],
        'fallbackRecommendation': 'concurrent_supported',
        'cameras': [
          <String, Object?>{
            'cameraId': '0',
            'lensFacing': 'back',
            'sensorOrientation': 90,
            'hardwareLevel': 'level3',
            'isLogicalMultiCamera': true,
            'physicalCameraIds': ['2', '3'],
            'capabilities': ['BACKWARD_COMPATIBLE', 'LOGICAL_MULTI_CAMERA'],
            'previewSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'videoSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'jpegSizes': [
              {'width': 4000, 'height': 3000},
            ],
            'yuv420Sizes': [
              {'width': 1920, 'height': 1080},
            ],
            'fpsRanges': [
              {'lower': 30, 'upper': 30},
            ],
            'flashAvailable': true,
            'videoStabilizationModes': ['off', 'on'],
            'opticalStabilizationModes': ['off', 'on'],
            'sensorActiveArraySize': {
              'left': 0,
              'top': 0,
              'right': 4000,
              'bottom': 3000,
            },
            'sensorPixelArraySize': {'width': 4000, 'height': 3000},
            'mandatoryConcurrentStreamCombinations': <Object?>[],
          },
          <String, Object?>{
            'cameraId': '1',
            'lensFacing': 'front',
            'sensorOrientation': 270,
            'hardwareLevel': 'full',
            'isLogicalMultiCamera': false,
            'physicalCameraIds': <String>[],
            'capabilities': ['BACKWARD_COMPATIBLE'],
            'previewSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'videoSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'jpegSizes': [
              {'width': 3264, 'height': 2448},
            ],
            'yuv420Sizes': [
              {'width': 1920, 'height': 1080},
            ],
            'fpsRanges': [
              {'lower': 30, 'upper': 30},
            ],
            'flashAvailable': false,
            'videoStabilizationModes': ['off'],
            'opticalStabilizationModes': ['off'],
            'sensorActiveArraySize': {
              'left': 0,
              'top': 0,
              'right': 3264,
              'bottom': 2448,
            },
            'sensorPixelArraySize': {'width': 3264, 'height': 2448},
            'mandatoryConcurrentStreamCombinations': <Object?>[],
          },
          <String, Object?>{
            'cameraId': '2',
            'lensFacing': 'back',
            'sensorOrientation': 90,
            'hardwareLevel': 'full',
            'isLogicalMultiCamera': false,
            'physicalCameraIds': <String>[],
            'capabilities': ['BACKWARD_COMPATIBLE'],
            'previewSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'videoSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'jpegSizes': [
              {'width': 4000, 'height': 3000},
            ],
            'yuv420Sizes': [
              {'width': 1920, 'height': 1080},
            ],
            'fpsRanges': [
              {'lower': 30, 'upper': 30},
            ],
            'flashAvailable': true,
            'videoStabilizationModes': ['off', 'on'],
            'opticalStabilizationModes': ['off', 'on'],
            'sensorActiveArraySize': {
              'left': 0,
              'top': 0,
              'right': 4000,
              'bottom': 3000,
            },
            'sensorPixelArraySize': {'width': 4000, 'height': 3000},
            'mandatoryConcurrentStreamCombinations': <Object?>[],
          },
          <String, Object?>{
            'cameraId': '3',
            'lensFacing': 'back',
            'sensorOrientation': 90,
            'hardwareLevel': 'full',
            'isLogicalMultiCamera': false,
            'physicalCameraIds': <String>[],
            'capabilities': ['BACKWARD_COMPATIBLE'],
            'previewSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'videoSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'jpegSizes': [
              {'width': 4000, 'height': 3000},
            ],
            'yuv420Sizes': [
              {'width': 1920, 'height': 1080},
            ],
            'fpsRanges': [
              {'lower': 30, 'upper': 30},
            ],
            'flashAvailable': false,
            'videoStabilizationModes': ['off'],
            'opticalStabilizationModes': ['off', 'on'],
            'sensorActiveArraySize': {
              'left': 0,
              'top': 0,
              'right': 4000,
              'bottom': 3000,
            },
            'sensorPixelArraySize': {'width': 4000, 'height': 3000},
            'mandatoryConcurrentStreamCombinations': <Object?>[],
          },
        ],
      };

      test('parses logical multi-camera and physical camera IDs', () {
        final report = VGCameraHardwareCapabilityReport.fromMap(
          multiCameraReportMap,
        );

        expect(report.success, isTrue);
        expect(report.cameraCount, equals(4));
        expect(report.cameras.length, equals(4));

        final cam0 = report.cameras[0];
        expect(cam0.cameraId, equals('0'));
        expect(cam0.lensFacing, equals('back'));
        expect(cam0.isLogicalMultiCamera, isTrue);
        expect(cam0.physicalCameraIds, equals(['2', '3']));
        expect(cam0.capabilities, contains('LOGICAL_MULTI_CAMERA'));

        final cam1 = report.cameras[1];
        expect(cam1.cameraId, equals('1'));
        expect(cam1.lensFacing, equals('front'));
        expect(cam1.isLogicalMultiCamera, isFalse);
        expect(cam1.physicalCameraIds, isEmpty);
        expect(cam1.capabilities, isNot(contains('LOGICAL_MULTI_CAMERA')));

        final cam2 = report.cameras[2];
        expect(cam2.cameraId, equals('2'));
        expect(cam2.isLogicalMultiCamera, isFalse);
        expect(cam2.physicalCameraIds, isEmpty);

        final cam3 = report.cameras[3];
        expect(cam3.cameraId, equals('3'));
        expect(cam3.isLogicalMultiCamera, isFalse);
        expect(cam3.physicalCameraIds, isEmpty);
      });

      test('topology helper produces valid topology summary', () {
        final report = VGCameraHardwareCapabilityReport.fromMap(
          multiCameraReportMap,
        );
        final summary = _analyzeTopology(report);

        expect(summary.isValidTopology, isTrue);
        expect(summary.issues, isEmpty);
        expect(summary.totalCameraCount, equals(4));
        expect(summary.logicalCameraCount, equals(1));
        expect(summary.nonLogicalCameraCount, equals(3));
        expect(summary.logicalCameraIds, equals(['0']));
        expect(summary.physicalChildIds, equals(['2', '3']));
        expect(summary.uniquePhysicalChildIds, equals({'2', '3'}));
        expect(summary.publicCameraIds, equals(['0', '1', '2', '3']));
        expect(summary.hasLogicalCamera, isTrue);

        final summaryMap = summary.toMap();
        expect(summaryMap['isValidTopology'], isTrue);
        expect(summaryMap['logicalCameraCount'], equals(1));
      });

      test(
        'asserts parent camera ID is not present in its own physicalCameraIds',
        () {
          final report = VGCameraHardwareCapabilityReport.fromMap(
            multiCameraReportMap,
          );
          for (final cam in report.cameras.where(
            (c) => c.isLogicalMultiCamera,
          )) {
            expect(cam.physicalCameraIds.contains(cam.cameraId), isFalse);
          }
        },
      );

      test('asserts concurrent camera ID sets use only public camera IDs', () {
        final report = VGCameraHardwareCapabilityReport.fromMap(
          multiCameraReportMap,
        );
        final publicIds = report.cameras.map((c) => c.cameraId).toSet();
        for (final set in report.concurrentCameraIdSets) {
          for (final id in set) {
            expect(publicIds.contains(id), isTrue);
          }
        }
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Fixture with No Logical Multi-Cameras (Standard Topology)
    // ─────────────────────────────────────────────────────────────────────────
    group('No-logical-camera fixture (valid proof state)', () {
      final noLogicalReportMap = <String, Object?>{
        'success': true,
        'apiLevel': 36,
        'hasCameraPermission': true,
        'thermalStatus': 0,
        'thermalStatusName': 'none',
        'cameraCount': 4,
        'supportsConcurrentCamera': false,
        'concurrentCameraIdSets': <Object?>[],
        'fallbackRecommendation': 'single_camera_only',
        'cameras': [
          <String, Object?>{
            'cameraId': '0',
            'lensFacing': 'back',
            'sensorOrientation': 90,
            'hardwareLevel': 'level3',
            'isLogicalMultiCamera': false,
            'physicalCameraIds': <String>[],
            'capabilities': ['BACKWARD_COMPATIBLE'],
            'previewSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'videoSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'jpegSizes': [
              {'width': 4000, 'height': 3000},
            ],
            'yuv420Sizes': [
              {'width': 1920, 'height': 1080},
            ],
            'fpsRanges': [
              {'lower': 30, 'upper': 30},
            ],
            'flashAvailable': true,
            'videoStabilizationModes': ['off', 'on'],
            'opticalStabilizationModes': ['off', 'on'],
            'sensorActiveArraySize': {
              'left': 0,
              'top': 0,
              'right': 4000,
              'bottom': 3000,
            },
            'sensorPixelArraySize': {'width': 4000, 'height': 3000},
            'mandatoryConcurrentStreamCombinations': <Object?>[],
          },
          <String, Object?>{
            'cameraId': '1',
            'lensFacing': 'front',
            'sensorOrientation': 270,
            'hardwareLevel': 'full',
            'isLogicalMultiCamera': false,
            'physicalCameraIds': <String>[],
            'capabilities': ['BACKWARD_COMPATIBLE'],
            'previewSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'videoSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'jpegSizes': [
              {'width': 3264, 'height': 2448},
            ],
            'yuv420Sizes': [
              {'width': 1920, 'height': 1080},
            ],
            'fpsRanges': [
              {'lower': 30, 'upper': 30},
            ],
            'flashAvailable': false,
            'videoStabilizationModes': ['off'],
            'opticalStabilizationModes': ['off'],
            'sensorActiveArraySize': {
              'left': 0,
              'top': 0,
              'right': 3264,
              'bottom': 2448,
            },
            'sensorPixelArraySize': {'width': 3264, 'height': 2448},
            'mandatoryConcurrentStreamCombinations': <Object?>[],
          },
          <String, Object?>{
            'cameraId': '2',
            'lensFacing': 'back',
            'sensorOrientation': 90,
            'hardwareLevel': 'limited',
            'isLogicalMultiCamera': false,
            'physicalCameraIds': <String>[],
            'capabilities': ['BACKWARD_COMPATIBLE'],
            'previewSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'videoSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'jpegSizes': [
              {'width': 2592, 'height': 1944},
            ],
            'yuv420Sizes': [
              {'width': 1920, 'height': 1080},
            ],
            'fpsRanges': [
              {'lower': 30, 'upper': 30},
            ],
            'flashAvailable': false,
            'videoStabilizationModes': ['off'],
            'opticalStabilizationModes': ['off'],
            'sensorActiveArraySize': {
              'left': 0,
              'top': 0,
              'right': 2592,
              'bottom': 1944,
            },
            'sensorPixelArraySize': {'width': 2592, 'height': 1944},
            'mandatoryConcurrentStreamCombinations': <Object?>[],
          },
          <String, Object?>{
            'cameraId': '3',
            'lensFacing': 'back',
            'sensorOrientation': 90,
            'hardwareLevel': 'limited',
            'isLogicalMultiCamera': false,
            'physicalCameraIds': <String>[],
            'capabilities': ['BACKWARD_COMPATIBLE'],
            'previewSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'videoSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'jpegSizes': [
              {'width': 2592, 'height': 1944},
            ],
            'yuv420Sizes': [
              {'width': 1920, 'height': 1080},
            ],
            'fpsRanges': [
              {'lower': 30, 'upper': 30},
            ],
            'flashAvailable': false,
            'videoStabilizationModes': ['off'],
            'opticalStabilizationModes': ['off'],
            'sensorActiveArraySize': {
              'left': 0,
              'top': 0,
              'right': 2592,
              'bottom': 1944,
            },
            'sensorPixelArraySize': {'width': 2592, 'height': 1944},
            'mandatoryConcurrentStreamCombinations': <Object?>[],
          },
        ],
      };

      test('validates no-logical-camera device as a valid topology state', () {
        final report = VGCameraHardwareCapabilityReport.fromMap(
          noLogicalReportMap,
        );
        expect(report.success, isTrue);
        expect(report.cameraCount, equals(4));

        final summary = _analyzeTopology(report);
        expect(summary.isValidTopology, isTrue);
        expect(summary.issues, isEmpty);
        expect(summary.logicalCameraCount, equals(0));
        expect(summary.nonLogicalCameraCount, equals(4));
        expect(summary.logicalCameraIds, isEmpty);
        expect(summary.physicalChildIds, isEmpty);
        expect(summary.uniquePhysicalChildIds, isEmpty);
        expect(summary.hasLogicalCamera, isFalse);
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 3. Defensive Malformed / Edge Topology Detection Tests
    // ─────────────────────────────────────────────────────────────────────────
    group('Malformed and edge topology fixtures', () {
      test('detects duplicate physical camera IDs in a logical camera', () {
        final malformedMap = <String, Object?>{
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': true,
          'thermalStatusName': 'none',
          'cameraCount': 1,
          'supportsConcurrentCamera': false,
          'concurrentCameraIdSets': <Object?>[],
          'fallbackRecommendation': 'single_camera_only',
          'cameras': [
            <String, Object?>{
              'cameraId': '0',
              'lensFacing': 'back',
              'hardwareLevel': 'level3',
              'isLogicalMultiCamera': true,
              'physicalCameraIds': ['2', '2'], // Duplicate physical child
              'capabilities': ['BACKWARD_COMPATIBLE', 'LOGICAL_MULTI_CAMERA'],
            },
          ],
        };

        final report = VGCameraHardwareCapabilityReport.fromMap(malformedMap);
        final summary = _analyzeTopology(report);

        expect(summary.isValidTopology, isFalse);
        expect(summary.issues, contains('duplicate_physical_camera_id:0:2'));
      });

      test(
        'detects logical camera including its own ID in physicalCameraIds',
        () {
          final malformedMap = <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'thermalStatusName': 'none',
            'cameraCount': 1,
            'supportsConcurrentCamera': false,
            'concurrentCameraIdSets': <Object?>[],
            'fallbackRecommendation': 'single_camera_only',
            'cameras': [
              <String, Object?>{
                'cameraId': '0',
                'lensFacing': 'back',
                'hardwareLevel': 'level3',
                'isLogicalMultiCamera': true,
                'physicalCameraIds': ['0', '2'], // Own ID included
                'capabilities': ['BACKWARD_COMPATIBLE', 'LOGICAL_MULTI_CAMERA'],
              },
            ],
          };

          final report = VGCameraHardwareCapabilityReport.fromMap(malformedMap);
          final summary = _analyzeTopology(report);

          expect(summary.isValidTopology, isFalse);
          expect(
            summary.issues,
            contains('parent_id_in_physical_camera_ids:0'),
          );
        },
      );

      test('detects logical flag without LOGICAL_MULTI_CAMERA capability', () {
        final malformedMap = <String, Object?>{
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': true,
          'thermalStatusName': 'none',
          'cameraCount': 1,
          'supportsConcurrentCamera': false,
          'concurrentCameraIdSets': <Object?>[],
          'fallbackRecommendation': 'single_camera_only',
          'cameras': [
            <String, Object?>{
              'cameraId': '0',
              'lensFacing': 'back',
              'hardwareLevel': 'level3',
              'isLogicalMultiCamera': true,
              'physicalCameraIds': ['2', '3'],
              'capabilities': [
                'BACKWARD_COMPATIBLE',
              ], // Missing capability token
            },
          ],
        };

        final report = VGCameraHardwareCapabilityReport.fromMap(malformedMap);
        final summary = _analyzeTopology(report);

        expect(summary.isValidTopology, isFalse);
        expect(
          summary.issues.any(
            (i) => i.startsWith('logical_flag_capability_mismatch:0'),
          ),
          isTrue,
        );
      });

      test(
        'detects LOGICAL_MULTI_CAMERA capability when isLogicalMultiCamera is false',
        () {
          final malformedMap = <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'thermalStatusName': 'none',
            'cameraCount': 1,
            'supportsConcurrentCamera': false,
            'concurrentCameraIdSets': <Object?>[],
            'fallbackRecommendation': 'single_camera_only',
            'cameras': [
              <String, Object?>{
                'cameraId': '0',
                'lensFacing': 'back',
                'hardwareLevel': 'level3',
                'isLogicalMultiCamera': false, // Incoherent flag
                'physicalCameraIds': <String>[],
                'capabilities': ['BACKWARD_COMPATIBLE', 'LOGICAL_MULTI_CAMERA'],
              },
            ],
          };

          final report = VGCameraHardwareCapabilityReport.fromMap(malformedMap);
          final summary = _analyzeTopology(report);

          expect(summary.isValidTopology, isFalse);
          expect(
            summary.issues.any(
              (i) => i.startsWith('logical_flag_capability_mismatch:0'),
            ),
            isTrue,
          );
        },
      );

      test('detects logical camera with empty physicalCameraIds', () {
        final malformedMap = <String, Object?>{
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': true,
          'thermalStatusName': 'none',
          'cameraCount': 1,
          'supportsConcurrentCamera': false,
          'concurrentCameraIdSets': <Object?>[],
          'fallbackRecommendation': 'single_camera_only',
          'cameras': [
            <String, Object?>{
              'cameraId': '0',
              'lensFacing': 'back',
              'hardwareLevel': 'level3',
              'isLogicalMultiCamera': true,
              'physicalCameraIds': <String>[], // Empty physical list
              'capabilities': ['BACKWARD_COMPATIBLE', 'LOGICAL_MULTI_CAMERA'],
            },
          ],
        };

        final report = VGCameraHardwareCapabilityReport.fromMap(malformedMap);
        final summary = _analyzeTopology(report);

        expect(summary.isValidTopology, isFalse);
        expect(summary.issues, contains('empty_physical_camera_ids:0'));
      });

      test(
        'detects concurrent camera ID set referencing non-public camera ID',
        () {
          final malformedMap = <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'thermalStatusName': 'none',
            'cameraCount': 2,
            'supportsConcurrentCamera': true,
            'concurrentCameraIdSets': [
              ['0', '99'], // '99' is not in public cameras list
            ],
            'fallbackRecommendation': 'concurrent_supported',
            'cameras': [
              <String, Object?>{
                'cameraId': '0',
                'lensFacing': 'back',
                'hardwareLevel': 'full',
                'isLogicalMultiCamera': false,
                'physicalCameraIds': <String>[],
                'capabilities': ['BACKWARD_COMPATIBLE'],
              },
              <String, Object?>{
                'cameraId': '1',
                'lensFacing': 'front',
                'hardwareLevel': 'full',
                'isLogicalMultiCamera': false,
                'physicalCameraIds': <String>[],
                'capabilities': ['BACKWARD_COMPATIBLE'],
              },
            ],
          };

          final report = VGCameraHardwareCapabilityReport.fromMap(malformedMap);
          final summary = _analyzeTopology(report);

          expect(summary.isValidTopology, isFalse);
          expect(
            summary.issues,
            contains('concurrent_set_contains_non_public_camera_id:99'),
          );
        },
      );

      test('detects duplicate public camera IDs in probe report', () {
        final malformedMap = <String, Object?>{
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': true,
          'thermalStatusName': 'none',
          'cameraCount': 2,
          'supportsConcurrentCamera': false,
          'concurrentCameraIdSets': <Object?>[],
          'fallbackRecommendation': 'single_camera_only',
          'cameras': [
            <String, Object?>{
              'cameraId': '0',
              'lensFacing': 'back',
              'hardwareLevel': 'full',
              'isLogicalMultiCamera': false,
              'physicalCameraIds': <String>[],
              'capabilities': ['BACKWARD_COMPATIBLE'],
            },
            <String, Object?>{
              'cameraId': '0', // Duplicate public ID
              'lensFacing': 'front',
              'hardwareLevel': 'full',
              'isLogicalMultiCamera': false,
              'physicalCameraIds': <String>[],
              'capabilities': ['BACKWARD_COMPATIBLE'],
            },
          ],
        };

        final report = VGCameraHardwareCapabilityReport.fromMap(malformedMap);
        final summary = _analyzeTopology(report);

        expect(summary.isValidTopology, isFalse);
        expect(summary.issues, contains('duplicate_public_camera_id:0'));
      });
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 4. MethodChannel Mock Contract Test
    // ─────────────────────────────────────────────────────────────────────────
    group('MethodChannel probe contract', () {
      test(
        'probeAndroidCamera2Capabilities receives logical/physical topology',
        () async {
          final mockResponse = <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'thermalStatus': 0,
            'thermalStatusName': 'none',
            'cameraCount': 2,
            'supportsConcurrentCamera': false,
            'concurrentCameraIdSets': <Object?>[],
            'fallbackRecommendation': 'single_camera_only',
            'cameras': [
              <String, Object?>{
                'cameraId': '0',
                'lensFacing': 'back',
                'sensorOrientation': 90,
                'hardwareLevel': 'level3',
                'isLogicalMultiCamera': true,
                'physicalCameraIds': ['2', '3'],
                'capabilities': ['BACKWARD_COMPATIBLE', 'LOGICAL_MULTI_CAMERA'],
                'previewSizes': [
                  {'width': 1920, 'height': 1080},
                ],
                'videoSizes': [
                  {'width': 1920, 'height': 1080},
                ],
                'jpegSizes': [
                  {'width': 4000, 'height': 3000},
                ],
                'yuv420Sizes': [
                  {'width': 1920, 'height': 1080},
                ],
                'fpsRanges': [
                  {'lower': 30, 'upper': 30},
                ],
                'flashAvailable': true,
                'videoStabilizationModes': ['off', 'on'],
                'opticalStabilizationModes': ['off'],
                'sensorActiveArraySize': {
                  'left': 0,
                  'top': 0,
                  'right': 4000,
                  'bottom': 3000,
                },
                'sensorPixelArraySize': {'width': 4000, 'height': 3000},
                'mandatoryConcurrentStreamCombinations': <Object?>[],
              },
              <String, Object?>{
                'cameraId': '1',
                'lensFacing': 'front',
                'sensorOrientation': 270,
                'hardwareLevel': 'full',
                'isLogicalMultiCamera': false,
                'physicalCameraIds': <String>[],
                'capabilities': ['BACKWARD_COMPATIBLE'],
                'previewSizes': [
                  {'width': 1920, 'height': 1080},
                ],
                'videoSizes': [
                  {'width': 1920, 'height': 1080},
                ],
                'jpegSizes': [
                  {'width': 3264, 'height': 2448},
                ],
                'yuv420Sizes': [
                  {'width': 1920, 'height': 1080},
                ],
                'fpsRanges': [
                  {'lower': 30, 'upper': 30},
                ],
                'flashAvailable': false,
                'videoStabilizationModes': ['off'],
                'opticalStabilizationModes': ['off'],
                'sensorActiveArraySize': {
                  'left': 0,
                  'top': 0,
                  'right': 3264,
                  'bottom': 2448,
                },
                'sensorPixelArraySize': {'width': 3264, 'height': 2448},
                'mandatoryConcurrentStreamCombinations': <Object?>[],
              },
            ],
          };

          binaryMessenger.setMockMethodCallHandler(defaultChannel, (
            MethodCall call,
          ) async {
            if (call.method ==
                'runAndroidDagPhase3UnitACameraCapabilityProbe') {
              return mockResponse;
            }
            return null;
          });

          final report =
              await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities();

          expect(report.success, isTrue);
          expect(report.cameraCount, equals(2));
          expect(report.cameras[0].isLogicalMultiCamera, isTrue);
          expect(report.cameras[0].physicalCameraIds, equals(['2', '3']));
          expect(report.cameras[1].isLogicalMultiCamera, isFalse);
          expect(report.cameras[1].physicalCameraIds, isEmpty);

          final summary = _analyzeTopology(report);
          expect(summary.isValidTopology, isTrue);
          expect(summary.logicalCameraCount, equals(1));
          expect(summary.physicalChildIds, equals(['2', '3']));
        },
      );
    });

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Model Roundtrip & Value Semantics
    // ─────────────────────────────────────────────────────────────────────────
    group('Model roundtrip and value semantics', () {
      test(
        'VGCameraHardwareDeviceCapability toMap/fromMap preserves topology fields',
        () {
          final map = <String, Object?>{
            'cameraId': '0',
            'lensFacing': 'back',
            'sensorOrientation': 90,
            'hardwareLevel': 'level3',
            'isLogicalMultiCamera': true,
            'physicalCameraIds': ['2', '3'],
            'capabilities': ['BACKWARD_COMPATIBLE', 'LOGICAL_MULTI_CAMERA'],
            'previewSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'videoSizes': [
              {'width': 1920, 'height': 1080},
            ],
            'jpegSizes': [
              {'width': 4000, 'height': 3000},
            ],
            'yuv420Sizes': [
              {'width': 1920, 'height': 1080},
            ],
            'fpsRanges': [
              {'lower': 30, 'upper': 30},
            ],
            'flashAvailable': true,
            'videoStabilizationModes': ['off', 'on'],
            'opticalStabilizationModes': ['off'],
            'sensorActiveArraySize': {
              'left': 0,
              'top': 0,
              'right': 4000,
              'bottom': 3000,
            },
            'sensorPixelArraySize': {'width': 4000, 'height': 3000},
            'mandatoryConcurrentStreamCombinations': <Object?>[],
          };

          final device = VGCameraHardwareDeviceCapability.fromMap(map);
          expect(device, isNotNull);
          expect(device!.isLogicalMultiCamera, isTrue);
          expect(device.physicalCameraIds, equals(['2', '3']));

          final outMap = device.toMap();
          expect(outMap['isLogicalMultiCamera'], isTrue);
          expect(outMap['physicalCameraIds'], equals(['2', '3']));

          final roundTripped = VGCameraHardwareDeviceCapability.fromMap(outMap);
          expect(roundTripped, equals(device));
        },
      );
    });
  });
}
