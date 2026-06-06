// vg_multicam_device_set_test.dart
// vanguard_media_engine — MC-2: Tests for VGMultiCamDevice and VGMultiCamDeviceSet
//
// All 18 required MC-2 tests.
// No Flutter binding required — pure Dart value object tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  // Canonical mock matching the shape returned by the native channel.
  // Mirrors the kMockDeviceSets fixture used in vg_camera_session_test.dart.
  final kFrontDevice = <String, Object?>{
    'uniqueId': 'AVCaptureDevice-Front-001',
    'localizedName': 'Front Camera',
    'position': 'front',
    'deviceType': 'builtInTrueDepthCamera',
    'modelId': 'iPhone16,2',
    'manufacturer': 'Apple Inc.',
  };

  final kBackWideDevice = <String, Object?>{
    'uniqueId': 'AVCaptureDevice-Back-001',
    'localizedName': 'Back Camera',
    'position': 'back',
    'deviceType': 'builtInWideAngleCamera',
    'modelId': 'iPhone16,2',
    'manufacturer': 'Apple Inc.',
  };

  final kBackUltraDevice = <String, Object?>{
    'uniqueId': 'AVCaptureDevice-Back-Ultra-001',
    'localizedName': 'Back Ultra Wide Camera',
    'position': 'back',
    'deviceType': 'builtInUltraWideCamera',
    'modelId': 'iPhone16,2',
    'manufacturer': 'Apple Inc.',
  };

  final kMockRawSets = <List<Map<String, Object?>>>[
    [kFrontDevice, kBackWideDevice],
    [kFrontDevice, kBackUltraDevice],
  ];

  group('VGMultiCamDevice (MC-2)', () {
    // ── 1. All six fields parsed ───────────────────────────────────────────
    test('1. VGMultiCamDevice.fromMap parses all six fields correctly', () {
      final device = VGMultiCamDevice.fromMap(kFrontDevice);

      expect(device, isNotNull);
      expect(device!.uniqueId, 'AVCaptureDevice-Front-001');
      expect(device.localizedName, 'Front Camera');
      expect(device.position, VGMultiCamDevicePosition.front);
      expect(device.deviceType, 'builtInTrueDepthCamera');
      expect(device.modelId, 'iPhone16,2');
      expect(device.manufacturer, 'Apple Inc.');
    });

    // ── 2. Null uniqueId → null ────────────────────────────────────────────
    test('2. VGMultiCamDevice.fromMap returns null when uniqueId is missing', () {
      final map = <String, Object?>{
        'localizedName': 'Ghost Camera',
        'position': 'back',
        'deviceType': 'builtInWideAngleCamera',
      };
      expect(VGMultiCamDevice.fromMap(map), isNull);
    });

    // ── 3. Empty uniqueId → null ───────────────────────────────────────────
    test('3. VGMultiCamDevice.fromMap returns null when uniqueId is empty string', () {
      final map = <String, Object?>{
        'uniqueId': '',
        'localizedName': 'Back Camera',
        'position': 'back',
        'deviceType': 'builtInWideAngleCamera',
      };
      expect(VGMultiCamDevice.fromMap(map), isNull);
    });

    // ── 4. Missing localizedName defaults to '' ────────────────────────────
    test('4. VGMultiCamDevice.fromMap defaults localizedName to empty string when missing', () {
      final map = <String, Object?>{
        'uniqueId': 'AVCaptureDevice-Test-001',
        'position': 'back',
        'deviceType': 'builtInWideAngleCamera',
      };
      final device = VGMultiCamDevice.fromMap(map);

      expect(device, isNotNull);
      expect(device!.localizedName, '');
    });

    // ── 5. All four position strings map correctly ─────────────────────────
    test('5. VGMultiCamDevice.fromMap maps position strings correctly', () {
      VGMultiCamDevice parse(String pos) =>
          VGMultiCamDevice.fromMap({'uniqueId': 'id', 'position': pos})!;

      expect(parse('front').position, VGMultiCamDevicePosition.front);
      expect(parse('back').position, VGMultiCamDevicePosition.back);
      expect(parse('unspecified').position, VGMultiCamDevicePosition.unspecified);
      expect(parse('unknown').position, VGMultiCamDevicePosition.unknown);
    });

    // ── 6. Unknown position string → unknown ──────────────────────────────
    test('6. VGMultiCamDevice.fromMap defaults unknown position string to unknown', () {
      final map = <String, Object?>{'uniqueId': 'id', 'position': 'sideways'};
      final device = VGMultiCamDevice.fromMap(map);
      expect(device!.position, VGMultiCamDevicePosition.unknown);
    });

    // ── 7. modelId and manufacturer are optional ───────────────────────────
    test('7. VGMultiCamDevice.fromMap treats modelId and manufacturer as optional', () {
      final map = <String, Object?>{
        'uniqueId': 'id',
        'localizedName': 'Camera',
        'position': 'back',
        'deviceType': 'builtInWideAngleCamera',
        // modelId and manufacturer deliberately absent
      };
      final device = VGMultiCamDevice.fromMap(map);
      expect(device, isNotNull);
      expect(device!.modelId, isNull);
      expect(device.manufacturer, isNull);
    });

    // ── 8. Equality and hashCode ───────────────────────────────────────────
    test('8. VGMultiCamDevice equality and hashCode', () {
      final a = VGMultiCamDevice.fromMap(kFrontDevice)!;
      final b = VGMultiCamDevice.fromMap(kFrontDevice)!;
      final c = VGMultiCamDevice.fromMap(kBackWideDevice)!;

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a.hashCode, isNot(c.hashCode));
    });
  });

  group('VGMultiCamDeviceSet (MC-2)', () {
    late VGMultiCamDevice front;
    late VGMultiCamDevice backWide;
    late VGMultiCamDevice backUltra;

    setUp(() {
      front = VGMultiCamDevice.fromMap(kFrontDevice)!;
      backWide = VGMultiCamDevice.fromMap(kBackWideDevice)!;
      backUltra = VGMultiCamDevice.fromMap(kBackUltraDevice)!;
    });

    // ── 9. hasFrontCamera and hasBackCamera ──────────────────────────────
    test('9. VGMultiCamDeviceSet hasFrontCamera and hasBackCamera', () {
      final setWithBoth = VGMultiCamDeviceSet([front, backWide]);
      expect(setWithBoth.hasFrontCamera, isTrue);
      expect(setWithBoth.hasBackCamera, isTrue);

      final frontOnly = VGMultiCamDeviceSet([front]);
      expect(frontOnly.hasFrontCamera, isTrue);
      expect(frontOnly.hasBackCamera, isFalse);

      final backOnly = VGMultiCamDeviceSet([backWide]);
      expect(backOnly.hasFrontCamera, isFalse);
      expect(backOnly.hasBackCamera, isTrue);

      final empty = VGMultiCamDeviceSet([]);
      expect(empty.hasFrontCamera, isFalse);
      expect(empty.hasBackCamera, isFalse);
    });

    // ── 10. hasFrontBackPair ───────────────────────────────────────────────
    test('10. VGMultiCamDeviceSet hasFrontBackPair', () {
      final pair = VGMultiCamDeviceSet([front, backWide]);
      expect(pair.hasFrontBackPair, isTrue);

      final frontOnly = VGMultiCamDeviceSet([front]);
      expect(frontOnly.hasFrontBackPair, isFalse);

      final backOnly = VGMultiCamDeviceSet([backWide]);
      expect(backOnly.hasFrontBackPair, isFalse);

      final empty = VGMultiCamDeviceSet([]);
      expect(empty.hasFrontBackPair, isFalse);
    });

    // ── 11. frontDevice and backDevice accessors ─────────────────────────
    test('11. VGMultiCamDeviceSet frontDevice and backDevice accessors', () {
      final set = VGMultiCamDeviceSet([front, backWide]);
      expect(set.frontDevice, front);
      expect(set.backDevice, backWide);

      final backOnly = VGMultiCamDeviceSet([backUltra]);
      expect(backOnly.frontDevice, isNull);
      expect(backOnly.backDevice, backUltra);

      final empty = VGMultiCamDeviceSet([]);
      expect(empty.frontDevice, isNull);
      expect(empty.backDevice, isNull);
    });

    // ── 12. fromRawDeviceSets parses canonical mock data ─────────────────
    test('12. fromRawDeviceSets parses canonical mock data correctly', () {
      final typed = VGMultiCamDeviceSet.fromRawDeviceSets(kMockRawSets);

      expect(typed.length, 2);
      expect(typed[0].devices.length, 2);
      expect(typed[1].devices.length, 2);

      expect(typed[0].frontDevice?.uniqueId, 'AVCaptureDevice-Front-001');
      expect(typed[0].backDevice?.uniqueId, 'AVCaptureDevice-Back-001');
      expect(typed[0].frontDevice?.position, VGMultiCamDevicePosition.front);
      expect(typed[0].backDevice?.position, VGMultiCamDevicePosition.back);

      expect(typed[1].backDevice?.deviceType, 'builtInUltraWideCamera');
    });

    // ── 13. fromRawDeviceSets silently drops invalid devices ──────────────
    test('13. fromRawDeviceSets silently drops devices with missing uniqueId', () {
      final rawSetsWithInvalid = <List<Map<String, Object?>>>[
        [
          kFrontDevice,
          <String, Object?>{
            // uniqueId deliberately absent
            'localizedName': 'Broken Device',
            'position': 'back',
            'deviceType': 'builtInWideAngleCamera',
          },
        ],
      ];

      final typed = VGMultiCamDeviceSet.fromRawDeviceSets(rawSetsWithInvalid);

      // The set is still included but has only 1 valid device.
      expect(typed.length, 1);
      expect(typed[0].devices.length, 1);
      expect(typed[0].devices[0].uniqueId, 'AVCaptureDevice-Front-001');
    });

    // ── 14. fromRawDeviceSets returns empty list for empty input ──────────
    test('14. fromRawDeviceSets returns empty list for empty input', () {
      final typed = VGMultiCamDeviceSet.fromRawDeviceSets([]);
      expect(typed, isEmpty);
    });

    // ── 15. selectFrontBackPair returns first valid pair ──────────────────
    test('15. selectFrontBackPair returns first set with both front and back', () {
      final typed = VGMultiCamDeviceSet.fromRawDeviceSets(kMockRawSets);
      final pair = VGMultiCamDeviceSet.selectFrontBackPair(typed);

      expect(pair, isNotNull);
      // Must be the FIRST qualifying set.
      expect(pair, typed[0]);
      expect(pair!.frontDevice?.deviceType, 'builtInTrueDepthCamera');
      expect(pair.backDevice?.deviceType, 'builtInWideAngleCamera');
    });

    // ── 16. selectFrontBackPair returns null when no valid pair exists ────
    test('16. selectFrontBackPair returns null when no set has both', () {
      final noFrontSets = <List<Map<String, Object?>>>[
        [kBackWideDevice],
        [kBackUltraDevice],
      ];
      final typed = VGMultiCamDeviceSet.fromRawDeviceSets(noFrontSets);
      final pair = VGMultiCamDeviceSet.selectFrontBackPair(typed);

      expect(pair, isNull);
    });

    // ── 17. selectFrontBackPair returns null for empty list ───────────────
    test('17. selectFrontBackPair returns null for empty list', () {
      final pair = VGMultiCamDeviceSet.selectFrontBackPair([]);
      expect(pair, isNull);
    });

    // ── 18. toMap round-trip contains no forbidden fields ─────────────────
    test('18. toMap round-trip does not contain MultiCam/AVCapture/session fields', () {
      final device = VGMultiCamDevice.fromMap(kFrontDevice)!;
      final map = device.toMap();

      // Required fields present.
      expect(map.containsKey('uniqueId'), isTrue);
      expect(map.containsKey('position'), isTrue);
      expect(map.containsKey('deviceType'), isTrue);

      // Verify no forbidden KEYS are present (values may contain AVCapture strings
      // because Apple device uniqueIDs are prefixed with 'AVCaptureDevice-').
      final keys = map.keys.toSet();
      expect(keys.any((k) => k.contains('MultiCam')), isFalse);
      expect(keys.any((k) => k.contains('AVCapture')), isFalse);
      expect(keys.any((k) => k.contains('session')), isFalse);
      expect(keys.any((k) => k.contains('primaryClip')), isFalse);
      expect(keys.any((k) => k.contains('secondaryClip')), isFalse);
      expect(keys.any((k) => k.contains('sourcePath')), isFalse);

      // Confirm no clip/session semantic keys exist.
      expect(map.containsKey('primaryClip'), isFalse);
      expect(map.containsKey('secondaryClip'), isFalse);
      expect(map.containsKey('sourcePath'), isFalse);
    });
  });
}
