// vg_android_multicam_capability_routes_smoke.dart
// vanguard_media_engine - P3-CAM-CONCURRENT-ANDROID-MULTICAM-CAPABILITY-WIRING:
// Android static MultiCam capability routes verification smoke foundation.
//
// Pure Dart typed report and runner proving Android static MultiCam capability
// routes (VGCameraSession.isMultiCamSupported and VGCameraSession.getMultiCamDeviceSets)
// are read-only, non-prompting, and consistent with the canonical Camera2 capability
// probe report without opening any camera, creating any preview, or capturing frames.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vg_camera_hardware_capability_report.dart';
import 'vg_camera_session.dart';

/// Proof boundary identifier for Android static MultiCam capability routes verification.
const String kAndroidMultiCamCapabilityRoutesProofBoundary =
    'android_multicam_capability_static_routes_read_only_probe_consistency_no_camera_open_no_preview_no_capture';

/// Physical smoke START marker token.
const String kAndroidMultiCamCapabilityRoutesStartMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_CAPABILITY_ROUTES_PHYSICAL_SMOKE_START';

/// Physical smoke PASS marker token.
const String kAndroidMultiCamCapabilityRoutesPassMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_CAPABILITY_ROUTES_PHYSICAL_SMOKE_PASS';

/// Physical smoke FAIL marker token.
const String kAndroidMultiCamCapabilityRoutesFailMarker =
    'ANDROID_DAG_PHASE3_MULTICAM_CAPABILITY_ROUTES_PHYSICAL_SMOKE_FAIL';

/// JSON payload log prefix.
const String kAndroidMultiCamCapabilityRoutesJsonPrefix =
    'ANDROID_DAG_PHASE3_MULTICAM_CAPABILITY_ROUTES_JSON:';

/// Immutable typed smoke report produced by [VGAndroidMultiCamCapabilityRoutesSmokeRunner].
@immutable
class VGAndroidMultiCamCapabilityRoutesSmokeReport {
  const VGAndroidMultiCamCapabilityRoutesSmokeReport({
    required this.pass,
    required this.proofBoundary,
    required this.staticSupported,
    required this.probeSupported,
    required this.deviceSetCount,
    required this.probeConcurrentSetCount,
    required this.unsupportedFailClosed,
    required this.staticSupportedMatchesProbe,
    required this.deviceSetCountMatchesProbe,
    required this.deviceMapShapeOk,
    required this.reasons,
    required this.diagnostics,
  });

  /// Whether all verification lanes passed.
  final bool pass;

  /// Exact proof boundary token.
  final String proofBoundary;

  /// Value returned by static route `VGCameraSession.isMultiCamSupported()`.
  final bool staticSupported;

  /// Value returned by `VGCameraHardwareCapabilityReport.supportsConcurrentCamera`.
  final bool probeSupported;

  /// Number of device sets returned by `VGCameraSession.getMultiCamDeviceSets()`.
  final int deviceSetCount;

  /// Number of concurrent camera ID sets with length >= 2 in probe report.
  final int probeConcurrentSetCount;

  /// Whether unsupported hardware fails closed (`staticSupported == false` and `deviceSetCount == 0`).
  final bool unsupportedFailClosed;

  /// Whether `staticSupported` equals `probeSupported`.
  final bool staticSupportedMatchesProbe;

  /// Whether `deviceSetCount` equals `probeConcurrentSetCount`.
  final bool deviceSetCountMatchesProbe;

  /// Whether every device descriptor map has non-empty string `uniqueId`,
  /// `localizedName`, `position`, and `deviceType`.
  final bool deviceMapShapeOk;

  /// Structured reason codes explaining the verdict.
  final List<String> reasons;

  /// Additional diagnostics capturing hardware and route evaluation state.
  final Map<String, Object?> diagnostics;

  /// Serializes this smoke report to a map.
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'pass': pass,
      'proofBoundary': proofBoundary,
      'staticSupported': staticSupported,
      'probeSupported': probeSupported,
      'deviceSetCount': deviceSetCount,
      'probeConcurrentSetCount': probeConcurrentSetCount,
      'unsupportedFailClosed': unsupportedFailClosed,
      'staticSupportedMatchesProbe': staticSupportedMatchesProbe,
      'deviceSetCountMatchesProbe': deviceSetCountMatchesProbe,
      'deviceMapShapeOk': deviceMapShapeOk,
      'reasons': reasons,
      'diagnostics': diagnostics,
    };
  }

  /// Deserializes a smoke report from a raw map, returning `null` if invalid.
  static VGAndroidMultiCamCapabilityRoutesSmokeReport? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final pass = raw['pass'] as bool? ?? false;
    final proofBoundary = raw['proofBoundary'] as String? ?? '';
    final staticSupported = raw['staticSupported'] as bool? ?? false;
    final probeSupported = raw['probeSupported'] as bool? ?? false;
    final deviceSetCount = (raw['deviceSetCount'] as num?)?.toInt() ?? 0;
    final probeConcurrentSetCount =
        (raw['probeConcurrentSetCount'] as num?)?.toInt() ?? 0;
    final unsupportedFailClosed =
        raw['unsupportedFailClosed'] as bool? ?? false;
    final staticSupportedMatchesProbe =
        raw['staticSupportedMatchesProbe'] as bool? ?? false;
    final deviceSetCountMatchesProbe =
        raw['deviceSetCountMatchesProbe'] as bool? ?? false;
    final deviceMapShapeOk = raw['deviceMapShapeOk'] as bool? ?? false;

    final reasonsRaw = raw['reasons'];
    final reasons = reasonsRaw is List
        ? reasonsRaw
              .whereType<Object>()
              .map((e) => e.toString())
              .toList(growable: false)
        : const <String>[];

    final diagMapRaw = raw['diagnostics'];
    final diagnostics = diagMapRaw is Map
        ? Map<String, Object?>.from(diagMapRaw)
        : const <String, Object?>{};

    return VGAndroidMultiCamCapabilityRoutesSmokeReport(
      pass: pass,
      proofBoundary: proofBoundary,
      staticSupported: staticSupported,
      probeSupported: probeSupported,
      deviceSetCount: deviceSetCount,
      probeConcurrentSetCount: probeConcurrentSetCount,
      unsupportedFailClosed: unsupportedFailClosed,
      staticSupportedMatchesProbe: staticSupportedMatchesProbe,
      deviceSetCountMatchesProbe: deviceSetCountMatchesProbe,
      deviceMapShapeOk: deviceMapShapeOk,
      reasons: reasons,
      diagnostics: diagnostics,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VGAndroidMultiCamCapabilityRoutesSmokeReport &&
        other.pass == pass &&
        other.proofBoundary == proofBoundary &&
        other.staticSupported == staticSupported &&
        other.probeSupported == probeSupported &&
        other.deviceSetCount == deviceSetCount &&
        other.probeConcurrentSetCount == probeConcurrentSetCount &&
        other.unsupportedFailClosed == unsupportedFailClosed &&
        other.staticSupportedMatchesProbe == staticSupportedMatchesProbe &&
        other.deviceSetCountMatchesProbe == deviceSetCountMatchesProbe &&
        other.deviceMapShapeOk == deviceMapShapeOk &&
        listEquals(other.reasons, reasons) &&
        mapEquals(other.diagnostics, diagnostics);
  }

  @override
  int get hashCode => Object.hash(
    pass,
    proofBoundary,
    staticSupported,
    probeSupported,
    deviceSetCount,
    probeConcurrentSetCount,
    unsupportedFailClosed,
    staticSupportedMatchesProbe,
    deviceSetCountMatchesProbe,
    deviceMapShapeOk,
    Object.hashAll(reasons),
    _stableMapHash(diagnostics),
  );

  static int _stableMapHash(Map<String, Object?> map) {
    final sortedKeys = map.keys.toList()..sort();
    return Object.hashAll(sortedKeys.map((k) => Object.hash(k, map[k])));
  }

  @override
  String toString() =>
      'VGAndroidMultiCamCapabilityRoutesSmokeReport('
      'pass: $pass, '
      'proofBoundary: $proofBoundary, '
      'staticSupported: $staticSupported, '
      'probeSupported: $probeSupported, '
      'deviceSetCount: $deviceSetCount, '
      'probeConcurrentSetCount: $probeConcurrentSetCount, '
      'unsupportedFailClosed: $unsupportedFailClosed, '
      'staticSupportedMatchesProbe: $staticSupportedMatchesProbe, '
      'deviceSetCountMatchesProbe: $deviceSetCountMatchesProbe, '
      'deviceMapShapeOk: $deviceMapShapeOk, '
      'reasons: $reasons)';
}

/// Runner that executes Android static MultiCam capability routes consistency checks.
class VGAndroidMultiCamCapabilityRoutesSmokeRunner {
  const VGAndroidMultiCamCapabilityRoutesSmokeRunner({
    this.probeHardwareReport,
    this.isMultiCamSupported,
    this.getMultiCamDeviceSets,
  });

  /// Injected probe capability function for testing.
  final Future<VGCameraHardwareCapabilityReport> Function({
    MethodChannel? channel,
  })?
  probeHardwareReport;

  /// Injected static MultiCam supported query for testing.
  final Future<bool> Function({MethodChannel? channel})? isMultiCamSupported;

  /// Injected static MultiCam device sets query for testing.
  final Future<List<List<Map<String, Object?>>>> Function({
    MethodChannel? channel,
  })?
  getMultiCamDeviceSets;

  /// Executes capability routes consistency smoke verification.
  Future<VGAndroidMultiCamCapabilityRoutesSmokeReport> runSmoke({
    MethodChannel? channel,
  }) async {
    try {
      final VGCameraHardwareCapabilityReport hardwareReport;
      if (probeHardwareReport != null) {
        hardwareReport = await probeHardwareReport!(channel: channel);
      } else {
        hardwareReport =
            await VGCameraHardwareCapabilityReport.probeAndroidCamera2Capabilities(
              channel: channel,
            );
      }

      bool staticSupported;
      if (isMultiCamSupported != null) {
        staticSupported = await isMultiCamSupported!(channel: channel);
      } else if (channel != null) {
        try {
          final res = await channel.invokeMethod<bool>('isMultiCamSupported');
          staticSupported = res ?? false;
        } on PlatformException {
          staticSupported = false;
        }
      } else {
        staticSupported = await VGCameraSession.isMultiCamSupported();
      }

      List<List<Map<String, Object?>>> deviceSets;
      if (getMultiCamDeviceSets != null) {
        deviceSets = await getMultiCamDeviceSets!(channel: channel);
      } else if (channel != null) {
        try {
          final raw = await channel.invokeMethod<List<Object?>>(
            'getMultiCamDeviceSets',
          );
          deviceSets = _parseDeviceSets(raw);
        } on PlatformException {
          deviceSets = <List<Map<String, Object?>>>[];
        }
      } else {
        deviceSets = await VGCameraSession.getMultiCamDeviceSets();
      }

      final probeSupported = hardwareReport.supportsConcurrentCamera;
      final probeConcurrentSetCount = hardwareReport.concurrentCameraIdSets
          .where((set) => set.length >= 2)
          .length;
      final deviceSetCount = deviceSets.length;

      final staticSupportedMatchesProbe = (staticSupported == probeSupported);
      final deviceSetCountMatchesProbe =
          (deviceSetCount == probeConcurrentSetCount);
      final unsupportedFailClosed = !probeSupported
          ? (!staticSupported && deviceSetCount == 0)
          : true;

      var deviceMapShapeOk = true;
      for (final set in deviceSets) {
        for (final dev in set) {
          final uid = dev['uniqueId'];
          final loc = dev['localizedName'];
          final pos = dev['position'];
          final type = dev['deviceType'];
          if (uid is! String ||
              uid.isEmpty ||
              loc is! String ||
              loc.isEmpty ||
              pos is! String ||
              pos.isEmpty ||
              type is! String ||
              type.isEmpty) {
            deviceMapShapeOk = false;
            break;
          }
        }
        if (!deviceMapShapeOk) break;
      }

      var deviceSetsMinLengthOk = true;
      for (final set in deviceSets) {
        if (set.length < 2) {
          deviceSetsMinLengthOk = false;
          break;
        }
      }

      final reasons = <String>[];
      if (!staticSupportedMatchesProbe) {
        reasons.add('static_supported_mismatches_probe');
      }
      if (!deviceSetCountMatchesProbe) {
        reasons.add('device_set_count_mismatches_probe');
      }
      if (!unsupportedFailClosed) {
        reasons.add('unsupported_hardware_not_fail_closed');
      }
      if (!deviceMapShapeOk) {
        reasons.add('malformed_device_descriptor_shape');
      }
      if (!deviceSetsMinLengthOk) {
        reasons.add('device_set_member_count_lt_2');
      }

      final pass =
          staticSupportedMatchesProbe &&
          deviceSetCountMatchesProbe &&
          unsupportedFailClosed &&
          deviceMapShapeOk &&
          deviceSetsMinLengthOk;

      if (pass) {
        reasons.add(
          probeSupported
              ? 'multicam_routes_supported_probe_consistent_pass'
              : 'multicam_routes_unsupported_probe_consistent_pass',
        );
      }

      final diagnostics = <String, Object?>{
        'proofBoundary': kAndroidMultiCamCapabilityRoutesProofBoundary,
        'isPhysicalDualCamera': probeSupported,
        'staticSupported': staticSupported,
        'probeSupported': probeSupported,
        'deviceSetCount': deviceSetCount,
        'probeConcurrentSetCount': probeConcurrentSetCount,
        'unsupportedFailClosed': unsupportedFailClosed,
        'staticSupportedMatchesProbe': staticSupportedMatchesProbe,
        'deviceSetCountMatchesProbe': deviceSetCountMatchesProbe,
        'deviceMapShapeOk': deviceMapShapeOk,
        'deviceSetsMinLengthOk': deviceSetsMinLengthOk,
        'supportsConcurrentCamera': hardwareReport.supportsConcurrentCamera,
        'cameraCount': hardwareReport.cameraCount,
        'concurrentCameraIdSets': hardwareReport.concurrentCameraIdSets,
        'rawDeviceSets': deviceSets,
      };

      return VGAndroidMultiCamCapabilityRoutesSmokeReport(
        pass: pass,
        proofBoundary: kAndroidMultiCamCapabilityRoutesProofBoundary,
        staticSupported: staticSupported,
        probeSupported: probeSupported,
        deviceSetCount: deviceSetCount,
        probeConcurrentSetCount: probeConcurrentSetCount,
        unsupportedFailClosed: unsupportedFailClosed,
        staticSupportedMatchesProbe: staticSupportedMatchesProbe,
        deviceSetCountMatchesProbe: deviceSetCountMatchesProbe,
        deviceMapShapeOk: deviceMapShapeOk,
        reasons: reasons,
        diagnostics: diagnostics,
      );
    } catch (e, st) {
      return VGAndroidMultiCamCapabilityRoutesSmokeReport(
        pass: false,
        proofBoundary: kAndroidMultiCamCapabilityRoutesProofBoundary,
        staticSupported: false,
        probeSupported: false,
        deviceSetCount: 0,
        probeConcurrentSetCount: 0,
        unsupportedFailClosed: false,
        staticSupportedMatchesProbe: false,
        deviceSetCountMatchesProbe: false,
        deviceMapShapeOk: false,
        reasons: <String>['exception_during_smoke_run: $e'],
        diagnostics: <String, Object?>{
          'proofBoundary': kAndroidMultiCamCapabilityRoutesProofBoundary,
          'isPhysicalDualCamera': false,
          'error': '$e\n$st',
        },
      );
    }
  }

  static List<List<Map<String, Object?>>> _parseDeviceSets(Object? raw) {
    if (raw is! List) return <List<Map<String, Object?>>>[];
    return raw.map((setRaw) {
      if (setRaw is! List) return <Map<String, Object?>>[];
      return setRaw.map((deviceRaw) {
        if (deviceRaw is! Map) return <String, Object?>{};
        return Map<String, Object?>.from(deviceRaw);
      }).toList();
    }).toList();
  }

  /// Convenience static runner method.
  static Future<VGAndroidMultiCamCapabilityRoutesSmokeReport> run({
    MethodChannel? channel,
    VGAndroidMultiCamCapabilityRoutesSmokeRunner? runner,
  }) {
    final activeRunner =
        runner ?? const VGAndroidMultiCamCapabilityRoutesSmokeRunner();
    return activeRunner.runSmoke(channel: channel);
  }
}
