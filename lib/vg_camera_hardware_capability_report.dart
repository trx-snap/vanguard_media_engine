// vg_camera_hardware_capability_report.dart
// vanguard_media_engine — Phase 3-Unit A: Android Camera2 hardware/thermal
// capability probe report.
//
// Pure Dart typed model over the raw Map returned by the native
// `runAndroidDagPhase3UnitACameraCapabilityProbe` MethodChannel route.
// Diagnostic/capability foundation only — no camera is opened, no texture
// is allocated, no permission is requested from this file.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A single output stream size (width x height) in pixels, as reported by
/// `StreamConfigurationMap.getOutputSizes`.
@immutable
class VGCameraSize {
  const VGCameraSize(this.width, this.height);

  final int width;
  final int height;

  static VGCameraSize? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final width = (raw['width'] as num?)?.toInt();
    final height = (raw['height'] as num?)?.toInt();
    if (width == null || height == null) return null;
    return VGCameraSize(width, height);
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{'width': width, 'height': height};
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCameraSize &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'VGCameraSize(width: $width, height: $height)';
}

/// A sensor rectangle (e.g. the active pixel array), as reported by
/// `CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE`.
@immutable
class VGCameraRect {
  const VGCameraRect(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  static VGCameraRect? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final left = (raw['left'] as num?)?.toInt();
    final top = (raw['top'] as num?)?.toInt();
    final right = (raw['right'] as num?)?.toInt();
    final bottom = (raw['bottom'] as num?)?.toInt();
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    return VGCameraRect(left, top, right, bottom);
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'left': left,
      'top': top,
      'right': right,
      'bottom': bottom,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCameraRect &&
        other.left == left &&
        other.top == top &&
        other.right == right &&
        other.bottom == bottom;
  }

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() =>
      'VGCameraRect(left: $left, top: $top, right: $right, bottom: $bottom)';
}

/// A supported target FPS range, as reported by
/// `CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES`.
@immutable
class VGCameraFpsRange {
  const VGCameraFpsRange(this.lower, this.upper);

  final int lower;
  final int upper;

  static VGCameraFpsRange? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final lower = (raw['lower'] as num?)?.toInt();
    final upper = (raw['upper'] as num?)?.toInt();
    if (lower == null || upper == null) return null;
    return VGCameraFpsRange(lower, upper);
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{'lower': lower, 'upper': upper};
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCameraFpsRange &&
        other.lower == lower &&
        other.upper == upper;
  }

  @override
  int get hashCode => Object.hash(lower, upper);

  @override
  String toString() => 'VGCameraFpsRange(lower: $lower, upper: $upper)';
}

/// A single camera device's static hardware capabilities, as reported by
/// `CameraManager.getCameraCharacteristics` on Android.
@immutable
class VGCameraHardwareDeviceCapability {
  const VGCameraHardwareDeviceCapability({
    required this.cameraId,
    required this.lensFacing,
    this.sensorOrientation,
    required this.hardwareLevel,
    required this.isLogicalMultiCamera,
    required this.physicalCameraIds,
    required this.capabilities,
    this.previewSizes = const <VGCameraSize>[],
    this.videoSizes = const <VGCameraSize>[],
    this.jpegSizes = const <VGCameraSize>[],
    this.yuv420Sizes = const <VGCameraSize>[],
    this.fpsRanges = const <VGCameraFpsRange>[],
    this.flashAvailable = false,
    this.videoStabilizationModes = const <String>[],
    this.opticalStabilizationModes = const <String>[],
    this.sensorActiveArraySize,
    this.sensorPixelArraySize,
  });

  /// Native Camera2 camera id string (`CameraManager.getCameraIdList()` entry).
  final String cameraId;

  /// `front` / `back` / `external` / `unknown`.
  final String lensFacing;

  /// Sensor mount angle in degrees, or `null` if unavailable.
  final int? sensorOrientation;

  /// `legacy` / `limited` / `full` / `level3` / `external` / `unknown`.
  final String hardwareLevel;

  /// Whether `REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA` is present.
  final bool isLogicalMultiCamera;

  /// Underlying physical camera ids for a logical multi-camera. Empty on
  /// API < 28 or for non-logical cameras.
  final List<String> physicalCameraIds;

  /// Symbolic capability names (e.g. `BACKWARD_COMPATIBLE`,
  /// `LOGICAL_MULTI_CAMERA`). Unrecognised native ints are preserved as
  /// `capability_<n>`.
  final List<String> capabilities;

  /// Supported preview (`SurfaceTexture`) output sizes, largest area first.
  final List<VGCameraSize> previewSizes;

  /// Supported video (`MediaRecorder`) output sizes, largest area first.
  final List<VGCameraSize> videoSizes;

  /// Supported JPEG (`ImageFormat.JPEG`) output sizes, largest area first.
  final List<VGCameraSize> jpegSizes;

  /// Supported YUV_420_888 output sizes, largest area first.
  final List<VGCameraSize> yuv420Sizes;

  /// Supported auto-exposure target FPS ranges.
  final List<VGCameraFpsRange> fpsRanges;

  /// Whether the device reports a flash unit (`FLASH_INFO_AVAILABLE`).
  final bool flashAvailable;

  /// Supported video stabilization modes (`off` / `on` / `unknown_<n>`).
  final List<String> videoStabilizationModes;

  /// Supported optical image stabilization modes (`off` / `on` /
  /// `unknown_<n>`).
  final List<String> opticalStabilizationModes;

  /// Sensor active pixel array rectangle, or `null` if unavailable.
  final VGCameraRect? sensorActiveArraySize;

  /// Full sensor pixel array size, or `null` if unavailable.
  final VGCameraSize? sensorPixelArraySize;

  /// Parses a single camera entry. Returns `null` when [raw] is not a map or
  /// `cameraId` is absent/empty — the only field required to address a
  /// device on the native side.
  static VGCameraHardwareDeviceCapability? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final cameraId = raw['cameraId'] as String?;
    if (cameraId == null || cameraId.isEmpty) return null;

    return VGCameraHardwareDeviceCapability(
      cameraId: cameraId,
      lensFacing: (raw['lensFacing'] as String?) ?? 'unknown',
      sensorOrientation: (raw['sensorOrientation'] as num?)?.toInt(),
      hardwareLevel: (raw['hardwareLevel'] as String?) ?? 'unknown',
      isLogicalMultiCamera: raw['isLogicalMultiCamera'] as bool? ?? false,
      physicalCameraIds: _stringList(raw['physicalCameraIds']),
      capabilities: _stringList(raw['capabilities']),
      previewSizes: _sizeList(raw['previewSizes']),
      videoSizes: _sizeList(raw['videoSizes']),
      jpegSizes: _sizeList(raw['jpegSizes']),
      yuv420Sizes: _sizeList(raw['yuv420Sizes']),
      fpsRanges: _fpsRangeList(raw['fpsRanges']),
      flashAvailable: raw['flashAvailable'] as bool? ?? false,
      videoStabilizationModes: _stringList(raw['videoStabilizationModes']),
      opticalStabilizationModes: _stringList(raw['opticalStabilizationModes']),
      sensorActiveArraySize: VGCameraRect.fromMap(raw['sensorActiveArraySize']),
      sensorPixelArraySize: VGCameraSize.fromMap(raw['sensorPixelArraySize']),
    );
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw
        .whereType<Object>()
        .map((e) => e.toString())
        .toList(growable: false);
  }

  static List<VGCameraSize> _sizeList(Object? raw) {
    if (raw is! List) return const <VGCameraSize>[];
    return raw
        .map(VGCameraSize.fromMap)
        .whereType<VGCameraSize>()
        .toList(growable: false);
  }

  static List<VGCameraFpsRange> _fpsRangeList(Object? raw) {
    if (raw is! List) return const <VGCameraFpsRange>[];
    return raw
        .map(VGCameraFpsRange.fromMap)
        .whereType<VGCameraFpsRange>()
        .toList(growable: false);
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'cameraId': cameraId,
      'lensFacing': lensFacing,
      'sensorOrientation': sensorOrientation,
      'hardwareLevel': hardwareLevel,
      'isLogicalMultiCamera': isLogicalMultiCamera,
      'physicalCameraIds': physicalCameraIds,
      'capabilities': capabilities,
      'previewSizes': previewSizes
          .map((s) => s.toMap())
          .toList(growable: false),
      'videoSizes': videoSizes.map((s) => s.toMap()).toList(growable: false),
      'jpegSizes': jpegSizes.map((s) => s.toMap()).toList(growable: false),
      'yuv420Sizes': yuv420Sizes.map((s) => s.toMap()).toList(growable: false),
      'fpsRanges': fpsRanges.map((r) => r.toMap()).toList(growable: false),
      'flashAvailable': flashAvailable,
      'videoStabilizationModes': videoStabilizationModes,
      'opticalStabilizationModes': opticalStabilizationModes,
      'sensorActiveArraySize': sensorActiveArraySize?.toMap(),
      'sensorPixelArraySize': sensorPixelArraySize?.toMap(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCameraHardwareDeviceCapability &&
        other.cameraId == cameraId &&
        other.lensFacing == lensFacing &&
        other.sensorOrientation == sensorOrientation &&
        other.hardwareLevel == hardwareLevel &&
        other.isLogicalMultiCamera == isLogicalMultiCamera &&
        listEquals(other.physicalCameraIds, physicalCameraIds) &&
        listEquals(other.capabilities, capabilities) &&
        listEquals(other.previewSizes, previewSizes) &&
        listEquals(other.videoSizes, videoSizes) &&
        listEquals(other.jpegSizes, jpegSizes) &&
        listEquals(other.yuv420Sizes, yuv420Sizes) &&
        listEquals(other.fpsRanges, fpsRanges) &&
        other.flashAvailable == flashAvailable &&
        listEquals(other.videoStabilizationModes, videoStabilizationModes) &&
        listEquals(
          other.opticalStabilizationModes,
          opticalStabilizationModes,
        ) &&
        other.sensorActiveArraySize == sensorActiveArraySize &&
        other.sensorPixelArraySize == sensorPixelArraySize;
  }

  @override
  int get hashCode => Object.hash(
    cameraId,
    lensFacing,
    sensorOrientation,
    hardwareLevel,
    isLogicalMultiCamera,
    Object.hashAll(physicalCameraIds),
    Object.hashAll(capabilities),
    Object.hashAll(previewSizes),
    Object.hashAll(videoSizes),
    Object.hashAll(jpegSizes),
    Object.hash(
      Object.hashAll(yuv420Sizes),
      Object.hashAll(fpsRanges),
      flashAvailable,
      Object.hashAll(videoStabilizationModes),
      Object.hashAll(opticalStabilizationModes),
      sensorActiveArraySize,
      sensorPixelArraySize,
    ),
  );

  @override
  String toString() =>
      'VGCameraHardwareDeviceCapability('
      'cameraId: $cameraId, '
      'lensFacing: $lensFacing, '
      'sensorOrientation: $sensorOrientation, '
      'hardwareLevel: $hardwareLevel, '
      'isLogicalMultiCamera: $isLogicalMultiCamera, '
      'physicalCameraIds: $physicalCameraIds, '
      'capabilities: $capabilities, '
      'previewSizes: $previewSizes, '
      'videoSizes: $videoSizes, '
      'jpegSizes: $jpegSizes, '
      'yuv420Sizes: $yuv420Sizes, '
      'fpsRanges: $fpsRanges, '
      'flashAvailable: $flashAvailable, '
      'videoStabilizationModes: $videoStabilizationModes, '
      'opticalStabilizationModes: $opticalStabilizationModes, '
      'sensorActiveArraySize: $sensorActiveArraySize, '
      'sensorPixelArraySize: $sensorPixelArraySize)';
}

/// Device-wide Android Camera2 hardware/thermal capability report, as
/// returned by the native `runAndroidDagPhase3UnitACameraCapabilityProbe`
/// MethodChannel route.
@immutable
class VGCameraHardwareCapabilityReport {
  const VGCameraHardwareCapabilityReport({
    required this.success,
    required this.apiLevel,
    required this.hasCameraPermission,
    this.thermalStatus,
    required this.thermalStatusName,
    required this.cameraCount,
    required this.supportsConcurrentCamera,
    required this.concurrentCameraIdSets,
    required this.cameras,
    required this.fallbackRecommendation,
  });

  /// Whether the native probe completed without throwing.
  final bool success;

  /// `Build.VERSION.SDK_INT` on the probing device.
  final int apiLevel;

  /// Current `Manifest.permission.CAMERA` grant state — queried without
  /// prompting.
  final bool hasCameraPermission;

  /// Raw `PowerManager.currentThermalStatus` (API 29+ only), or `null`.
  final int? thermalStatus;

  /// `none` / `light` / `moderate` / `severe` / `critical` / `emergency` /
  /// `shutdown` / `unavailable`.
  final String thermalStatusName;

  /// Number of cameras reported by `CameraManager.getCameraIdList()`.
  final int cameraCount;

  /// Whether any concurrent camera id set has 2 or more members.
  final bool supportsConcurrentCamera;

  /// `CameraManager.getConcurrentCameraIds()` sets (API 30+ only), each
  /// serialised as a list of camera ids.
  final List<List<String>> concurrentCameraIdSets;

  /// Per-camera static hardware capabilities.
  final List<VGCameraHardwareDeviceCapability> cameras;

  /// `concurrent_supported` / `single_camera_only` / `no_camera` /
  /// `thermal_blocked`.
  final String fallbackRecommendation;

  static const String _method = 'runAndroidDagPhase3UnitACameraCapabilityProbe';
  static const MethodChannel _defaultChannel = MethodChannel(
    'vanguard_media_engine',
  );

  /// Parses a report from the raw native map. Defensive against both
  /// `Map<Object?, Object?>` and `Map<String, Object?>` shapes, and against
  /// missing/malformed fields.
  static VGCameraHardwareCapabilityReport fromMap(Object? raw) {
    final map = raw is Map ? raw : const <Object?, Object?>{};

    final camerasRaw = map['cameras'];
    final cameras = camerasRaw is List
        ? camerasRaw
              .map(VGCameraHardwareDeviceCapability.fromMap)
              .whereType<VGCameraHardwareDeviceCapability>()
              .toList(growable: false)
        : const <VGCameraHardwareDeviceCapability>[];

    final concurrentRaw = map['concurrentCameraIdSets'];
    final concurrentCameraIdSets = concurrentRaw is List
        ? concurrentRaw
              .map(
                (set) => set is List
                    ? set
                          .whereType<Object>()
                          .map((e) => e.toString())
                          .toList(growable: false)
                    : const <String>[],
              )
              .toList(growable: false)
        : const <List<String>>[];

    return VGCameraHardwareCapabilityReport(
      success: map['success'] as bool? ?? false,
      apiLevel: (map['apiLevel'] as num?)?.toInt() ?? 0,
      hasCameraPermission: map['hasCameraPermission'] as bool? ?? false,
      thermalStatus: (map['thermalStatus'] as num?)?.toInt(),
      thermalStatusName: (map['thermalStatusName'] as String?) ?? 'unavailable',
      cameraCount: (map['cameraCount'] as num?)?.toInt() ?? cameras.length,
      supportsConcurrentCamera:
          map['supportsConcurrentCamera'] as bool? ?? false,
      concurrentCameraIdSets: concurrentCameraIdSets,
      cameras: cameras,
      fallbackRecommendation:
          (map['fallbackRecommendation'] as String?) ?? 'no_camera',
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'success': success,
      'apiLevel': apiLevel,
      'hasCameraPermission': hasCameraPermission,
      'thermalStatus': thermalStatus,
      'thermalStatusName': thermalStatusName,
      'cameraCount': cameraCount,
      'supportsConcurrentCamera': supportsConcurrentCamera,
      'concurrentCameraIdSets': concurrentCameraIdSets,
      'cameras': cameras.map((c) => c.toMap()).toList(growable: false),
      'fallbackRecommendation': fallbackRecommendation,
    };
  }

  /// Invokes the Android-backed native probe and parses the result.
  ///
  /// [channel] may be injected for testing; defaults to the shared
  /// `vanguard_media_engine` MethodChannel.
  static Future<VGCameraHardwareCapabilityReport>
  probeAndroidCamera2Capabilities({MethodChannel? channel}) async {
    final ch = channel ?? _defaultChannel;
    final raw = await ch.invokeMethod<Object?>(_method);
    return VGCameraHardwareCapabilityReport.fromMap(raw);
  }

  static bool _concurrentSetsEqual(List<List<String>> a, List<List<String>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!listEquals(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGCameraHardwareCapabilityReport &&
        other.success == success &&
        other.apiLevel == apiLevel &&
        other.hasCameraPermission == hasCameraPermission &&
        other.thermalStatus == thermalStatus &&
        other.thermalStatusName == thermalStatusName &&
        other.cameraCount == cameraCount &&
        other.supportsConcurrentCamera == supportsConcurrentCamera &&
        _concurrentSetsEqual(
          other.concurrentCameraIdSets,
          concurrentCameraIdSets,
        ) &&
        listEquals(other.cameras, cameras) &&
        other.fallbackRecommendation == fallbackRecommendation;
  }

  @override
  int get hashCode => Object.hash(
    success,
    apiLevel,
    hasCameraPermission,
    thermalStatus,
    thermalStatusName,
    cameraCount,
    supportsConcurrentCamera,
    Object.hashAll(concurrentCameraIdSets.map((set) => Object.hashAll(set))),
    Object.hashAll(cameras),
    fallbackRecommendation,
  );

  @override
  String toString() =>
      'VGCameraHardwareCapabilityReport('
      'success: $success, '
      'apiLevel: $apiLevel, '
      'hasCameraPermission: $hasCameraPermission, '
      'thermalStatus: $thermalStatus, '
      'thermalStatusName: $thermalStatusName, '
      'cameraCount: $cameraCount, '
      'supportsConcurrentCamera: $supportsConcurrentCamera, '
      'concurrentCameraIdSets: $concurrentCameraIdSets, '
      'cameras: $cameras, '
      'fallbackRecommendation: $fallbackRecommendation)';
}
