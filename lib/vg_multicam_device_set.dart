// vg_multicam_device_set.dart
// vanguard_media_engine — MC-2: Typed MultiCam device-set models
//
// ═══════════════════════════════════════════════════════════════════════════════
// MC-2 — TYPED MULTICAM DEVICE-SET MODELS AND DART SELECTION POLICY
// ═══════════════════════════════════════════════════════════════════════════════
//
// Pure Dart typed models over the raw Map-based return value of:
//   VGCameraSession.getMultiCamDeviceSets()
//   → Future<List<List<Map<String, Object?>>>>
//
// This file does NOT modify that API. It provides typed parsing on top of it:
//
//   final raw = await VGCameraSession.getMultiCamDeviceSets();
//   final typed = VGMultiCamDeviceSet.fromRawDeviceSets(raw);
//   final pair = VGMultiCamDeviceSet.selectFrontBackPair(typed);
//
// ── FIELD CONTRACT ────────────────────────────────────────────────────────────
//
//   uniqueId      REQUIRED — missing or empty → fromMap returns null
//   localizedName soft     — missing → defaults to ''
//   position      soft     — missing/unrecognized → VGMultiCamDevicePosition.unknown
//   deviceType    soft     — missing → defaults to 'unknown'
//   modelId       optional — missing → null
//   manufacturer  optional — missing → null
//
// ── CONSTRAINTS ──────────────────────────────────────────────────────────────
//
//   DO NOT add AVCaptureMultiCamSession allocation.
//   DO NOT add live-capture logic.
//   DO NOT add device-type ranking or preference.
//   DO NOT import or reference vg_camera_session.dart.
//

import 'package:flutter/foundation.dart';

// ─── VGMultiCamDevicePosition ─────────────────────────────────────────────────

/// Camera position as reported by `AVCaptureDevice.position` on iOS.
enum VGMultiCamDevicePosition {
  /// Front-facing camera (selfie / TrueDepth).
  front,

  /// Rear-facing camera (wide, telephoto, ultra-wide, etc.).
  back,

  /// Position not specified by the hardware.
  unspecified,

  /// Unrecognised position string from the native layer.
  unknown,
}

// ─── VGMultiCamDevice ─────────────────────────────────────────────────────────

/// A single camera device within a MultiCam-compatible device set.
///
/// Parses and wraps the per-device map returned by the native
/// `getMultiCamDeviceSets` channel method. The native map shape is:
///
/// | Key             | Type   | Required | Example                      |
/// |:--------------- |:------ |:-------- |:---------------------------- |
/// | `uniqueId`      | String | **Yes**  | `"AVCaptureDevice-…"`        |
/// | `localizedName` | String | Soft     | `"Back Camera"`              |
/// | `position`      | String | Soft     | `"front"` / `"back"` / …    |
/// | `deviceType`    | String | Soft     | `"builtInWideAngleCamera"`   |
/// | `modelId`       | String | No       | `"iPhone16,2"`               |
/// | `manufacturer`  | String | No       | `"Apple Inc."`               |
///
/// [fromMap] returns `null` only when `uniqueId` is absent or empty — the only
/// field required to address a device on the native side.
@immutable
class VGMultiCamDevice {
  const VGMultiCamDevice({
    required this.uniqueId,
    required this.localizedName,
    required this.position,
    required this.deviceType,
    this.modelId,
    this.manufacturer,
  });

  /// The device's unique hardware identifier (`AVCaptureDevice.uniqueID`).
  /// This is the only field required; missing or empty → [fromMap] returns null.
  final String uniqueId;

  /// Human-readable device name (`AVCaptureDevice.localizedName`).
  /// Defaults to `''` when absent from the native map.
  final String localizedName;

  /// Camera position. Defaults to [VGMultiCamDevicePosition.unknown] for any
  /// unrecognised or absent position string.
  final VGMultiCamDevicePosition position;

  /// Device type string as serialised by the native layer
  /// (e.g. `"builtInWideAngleCamera"`, `"builtInTrueDepthCamera"`).
  /// Defaults to `'unknown'` when absent.
  final String deviceType;

  /// Optional model identifier (`AVCaptureDevice.modelID`). May be `null`.
  final String? modelId;

  /// Optional manufacturer string (`AVCaptureDevice.manufacturer`). May be `null`.
  final String? manufacturer;

  // ── fromMap ────────────────────────────────────────────────────────────────

  /// Parses a [VGMultiCamDevice] from the per-device map returned by the
  /// native channel.
  ///
  /// Returns `null` if [map] is `null`, or if `uniqueId` is absent or empty.
  static VGMultiCamDevice? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;

    final rawUniqueId = map['uniqueId'] as String?;
    if (rawUniqueId == null || rawUniqueId.isEmpty) return null;

    final localizedName = (map['localizedName'] as String?) ?? '';
    final deviceType = (map['deviceType'] as String?) ?? 'unknown';
    final modelId = map['modelId'] as String?;
    final manufacturer = map['manufacturer'] as String?;
    final position = _parsePosition(map['position'] as String?);

    return VGMultiCamDevice(
      uniqueId: rawUniqueId,
      localizedName: localizedName,
      position: position,
      deviceType: deviceType,
      modelId: modelId,
      manufacturer: manufacturer,
    );
  }

  static VGMultiCamDevicePosition _parsePosition(String? raw) {
    switch (raw) {
      case 'front':
        return VGMultiCamDevicePosition.front;
      case 'back':
        return VGMultiCamDevicePosition.back;
      case 'unspecified':
        return VGMultiCamDevicePosition.unspecified;
      default:
        return VGMultiCamDevicePosition.unknown;
    }
  }

  // ── toMap ──────────────────────────────────────────────────────────────────

  /// Serialises this device back to a map.
  ///
  /// The output key set intentionally matches the native channel map shape.
  /// `modelId` and `manufacturer` are omitted when null so the map remains
  /// minimal and free of null entries.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'uniqueId': uniqueId,
      'localizedName': localizedName,
      'position': _positionToString(position),
      'deviceType': deviceType,
      if (modelId != null) 'modelId': modelId,
      if (manufacturer != null) 'manufacturer': manufacturer,
    };
  }

  static String _positionToString(VGMultiCamDevicePosition position) {
    switch (position) {
      case VGMultiCamDevicePosition.front:
        return 'front';
      case VGMultiCamDevicePosition.back:
        return 'back';
      case VGMultiCamDevicePosition.unspecified:
        return 'unspecified';
      case VGMultiCamDevicePosition.unknown:
        return 'unknown';
    }
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGMultiCamDevice &&
          runtimeType == other.runtimeType &&
          uniqueId == other.uniqueId &&
          localizedName == other.localizedName &&
          position == other.position &&
          deviceType == other.deviceType &&
          modelId == other.modelId &&
          manufacturer == other.manufacturer;

  @override
  int get hashCode => Object.hash(
        uniqueId,
        localizedName,
        position,
        deviceType,
        modelId,
        manufacturer,
      );

  @override
  String toString() =>
      'VGMultiCamDevice('
      'uniqueId: $uniqueId, '
      'localizedName: $localizedName, '
      'position: $position, '
      'deviceType: $deviceType, '
      'modelId: $modelId, '
      'manufacturer: $manufacturer)';
}

// ─── VGMultiCamDeviceSet ──────────────────────────────────────────────────────

/// A set of camera devices that can be used simultaneously in an
/// `AVCaptureMultiCamSession`.
///
/// Each set is one element of the `supportedMultiCamDeviceSets` list returned
/// by `AVCaptureDevice.DiscoverySession`. Devices within a set have been
/// hardware-validated by iOS to support concurrent capture.
///
/// ## Usage
/// ```dart
/// final raw = await VGCameraSession.getMultiCamDeviceSets();
/// final typed = VGMultiCamDeviceSet.fromRawDeviceSets(raw);
/// final pair = VGMultiCamDeviceSet.selectFrontBackPair(typed);
/// if (pair != null) {
///   final front = pair.frontDevice!;
///   final back = pair.backDevice!;
///   // → pass front.uniqueId + back.uniqueId to the future native session call
/// }
/// ```
@immutable
class VGMultiCamDeviceSet {
  const VGMultiCamDeviceSet(this.devices);

  /// All devices in this hardware-validated set.
  final List<VGMultiCamDevice> devices;

  // ── Computed properties ────────────────────────────────────────────────────

  /// `true` if this set contains at least one front-facing camera.
  bool get hasFrontCamera =>
      devices.any((d) => d.position == VGMultiCamDevicePosition.front);

  /// `true` if this set contains at least one back-facing camera.
  bool get hasBackCamera =>
      devices.any((d) => d.position == VGMultiCamDevicePosition.back);

  /// `true` if this set contains both at least one front and one back camera.
  bool get hasFrontBackPair => hasFrontCamera && hasBackCamera;

  /// The first front-facing device in this set, or `null` if none.
  VGMultiCamDevice? get frontDevice => devices
      .where((d) => d.position == VGMultiCamDevicePosition.front)
      .firstOrNull;

  /// The first back-facing device in this set, or `null` if none.
  VGMultiCamDevice? get backDevice => devices
      .where((d) => d.position == VGMultiCamDevicePosition.back)
      .firstOrNull;

  // ── Factory ────────────────────────────────────────────────────────────────

  /// Parses the raw return value of [VGCameraSession.getMultiCamDeviceSets()]
  /// into typed [VGMultiCamDeviceSet] objects.
  ///
  /// Silently drops any individual device whose [VGMultiCamDevice.fromMap]
  /// returns `null` (i.e., devices with missing or empty `uniqueId`).
  /// Empty sets (after filtering) are still included so that count semantics
  /// remain consistent with the raw return.
  static List<VGMultiCamDeviceSet> fromRawDeviceSets(
    List<List<Map<String, Object?>>> rawSets,
  ) {
    return rawSets.map((rawSet) {
      final devices = rawSet
          .map((rawDevice) => VGMultiCamDevice.fromMap(rawDevice))
          .whereType<VGMultiCamDevice>()
          .toList();
      return VGMultiCamDeviceSet(devices);
    }).toList();
  }

  // ── Selection policy ───────────────────────────────────────────────────────

  /// Returns the first set in [sets] that contains at least one front-facing
  /// and at least one back-facing device, or `null` if no such set exists.
  ///
  /// **No ranking is applied.** Device-type preferences (e.g. preferring
  /// TrueDepth over other front cameras, or wide-angle over ultra-wide back
  /// cameras) are deliberately deferred to a future slice once real session
  /// allocation feedback is available.
  static VGMultiCamDeviceSet? selectFrontBackPair(
    List<VGMultiCamDeviceSet> sets,
  ) {
    for (final set in sets) {
      if (set.hasFrontBackPair) return set;
    }
    return null;
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGMultiCamDeviceSet &&
          runtimeType == other.runtimeType &&
          _listEquals(devices, other.devices);

  // Deep list equality without depending on collection package.
  static bool _listEquals(
    List<VGMultiCamDevice> a,
    List<VGMultiCamDevice> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(devices);

  @override
  String toString() => 'VGMultiCamDeviceSet(devices: $devices)';
}
