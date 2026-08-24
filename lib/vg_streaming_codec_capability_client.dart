// Copyright (c) Connects — Vanguard Phase 4C5J.
// Public streaming codec capability client.
//
// Safe to import on all platforms: methods catch [MissingPluginException]
// and return typed unsupported results instead of throwing.

import 'dart:async';

import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Codec Info Model
// ─────────────────────────────────────────────────────────────────────────────

/// Detailed capability descriptor for a specific video decoder format.
class VGStreamingCodecInfo {
  /// Codec identifier key (e.g. `'avc'`, `'hevc'`, `'av1'`).
  final String codecKey;

  /// MIME type string (e.g. `'video/avc'`, `'video/hevc'`, `'video/av01'`).
  final String mimeType;

  /// Whether at least one matching decoder is present on the device.
  final bool supported;

  /// Whether at least one hardware-accelerated decoder is present.
  final bool hardwareDecoderPresent;

  /// Whether at least one software-only fallback decoder is present.
  final bool softwareDecoderPresent;

  /// Total number of matching decoders registered in Android MediaCodecList.
  final int decoderCount;

  /// List of matching decoder component names reported by the platform.
  final List<String> decoderNames;

  /// Total number of supported profile and level combinations across decoders.
  final int profileLevelCount;

  const VGStreamingCodecInfo({
    required this.codecKey,
    required this.mimeType,
    required this.supported,
    required this.hardwareDecoderPresent,
    required this.softwareDecoderPresent,
    required this.decoderCount,
    required this.decoderNames,
    required this.profileLevelCount,
  });

  /// Constructs a [VGStreamingCodecInfo] defensively from a platform dictionary.
  factory VGStreamingCodecInfo.fromMap(Map<Object?, Object?> map) {
    final stringMap = _defensiveStringMap(map);
    final codecKey = stringMap['codecKey'] as String? ?? '';
    final mimeType = stringMap['mimeType'] as String? ?? '';
    final supported = stringMap['supported'] as bool? ?? false;
    final hardwareDecoderPresent =
        stringMap['hardwareDecoderPresent'] as bool? ?? false;
    final softwareDecoderPresent =
        stringMap['softwareDecoderPresent'] as bool? ?? false;
    final decoderCount = (stringMap['decoderCount'] as num?)?.toInt() ?? 0;
    final rawNames = stringMap['decoderNames'];
    final decoderNames = rawNames is List
        ? rawNames
              .map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList()
        : const <String>[];
    final profileLevelCount =
        (stringMap['profileLevelCount'] as num?)?.toInt() ?? 0;

    return VGStreamingCodecInfo(
      codecKey: codecKey,
      mimeType: mimeType,
      supported: supported,
      hardwareDecoderPresent: hardwareDecoderPresent,
      softwareDecoderPresent: softwareDecoderPresent,
      decoderCount: decoderCount,
      decoderNames: decoderNames,
      profileLevelCount: profileLevelCount,
    );
  }

  /// Converts to standard map format.
  Map<String, Object?> toMap() => {
    'codecKey': codecKey,
    'mimeType': mimeType,
    'supported': supported,
    'hardwareDecoderPresent': hardwareDecoderPresent,
    'softwareDecoderPresent': softwareDecoderPresent,
    'decoderCount': decoderCount,
    'decoderNames': decoderNames,
    'profileLevelCount': profileLevelCount,
  };

  @override
  String toString() =>
      'VGStreamingCodecInfo(key=$codecKey, mime=$mimeType, supported=$supported, hw=$hardwareDecoderPresent, sw=$softwareDecoderPresent, count=$decoderCount)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Capability Report Model
// ─────────────────────────────────────────────────────────────────────────────

/// Structured report of device streaming codec capabilities across AVC, HEVC, and AV1.
///
/// Returned by [VGStreamingCodecCapabilityClient.probe].
class VGStreamingCodecCapabilityReport {
  /// Whether overall capability verification passed (requires baseline AVC support).
  final bool pass;

  /// Platform engine phase identifier (e.g. `"Phase4C5A"` or `"unsupported"`).
  final String phase;

  /// Whether baseline AVC/H.264 decoder support is confirmed.
  final bool avcPass;

  /// Whether exactly 3 codec specifications were probed (AVC, HEVC, AV1).
  final bool codecCountPass;

  /// Whether server ladder policy compliance matches additive policy requirement.
  final bool fallbackPolicyPass;

  /// Whether guidance note for iOS mirror implementations is present.
  final bool iosMirrorNotePass;

  /// Whether AVC/H.264 decoding is supported on this device.
  final bool avcSupported;

  /// Whether HEVC/H.265 decoding is supported on this device (telemetry/advisory).
  final bool hevcSupported;

  /// Whether AV1 decoding is supported on this device (telemetry/advisory).
  final bool av1Supported;

  /// Android SDK level (API level) of the underlying device, or 0 if unknown/non-Android.
  final int androidSdk;

  /// Server ladder policy requirement string (e.g. `"add_hevc_av1_renditions_but_keep_avc_fallback"`).
  final String serverLadderPolicy;

  /// Guidance note for iOS mirror implementations.
  final String iosMirrorNote;

  /// Detailed capability descriptors for probed codecs (AVC, HEVC, AV1).
  final List<VGStreamingCodecInfo> codecs;

  /// Raw diagnostic probe dictionary returned by the native probe engine.
  final Map<String, Object?> probe;

  /// Raw diagnostic summary string from native platform engine.
  final String raw;

  /// Complete diagnostic telemetry dictionary returned by native platform engine.
  final Map<String, Object?> diagnostics;

  const VGStreamingCodecCapabilityReport({
    required this.pass,
    required this.phase,
    required this.avcPass,
    required this.codecCountPass,
    required this.fallbackPolicyPass,
    required this.iosMirrorNotePass,
    required this.avcSupported,
    required this.hevcSupported,
    required this.av1Supported,
    required this.androidSdk,
    required this.serverLadderPolicy,
    required this.iosMirrorNote,
    required this.codecs,
    required this.probe,
    required this.raw,
    required this.diagnostics,
  });

  /// Constructs a [VGStreamingCodecCapabilityReport] from a raw platform dictionary.
  factory VGStreamingCodecCapabilityReport.fromMap(Map<Object?, Object?> map) {
    final stringMap = _defensiveStringMap(map);

    final rawProbe = stringMap['probe'];
    final probe = rawProbe is Map
        ? _defensiveStringMap(rawProbe.cast<Object?, Object?>())
        : const <String, Object?>{};

    final pass = stringMap['pass'] as bool? ?? false;
    final phase =
        stringMap['phase'] as String? ??
        (probe['phase'] as String? ?? 'Phase4C5A');
    final avcPass = stringMap['avcPass'] as bool? ?? false;
    final codecCountPass = stringMap['codecCountPass'] as bool? ?? false;
    final fallbackPolicyPass =
        stringMap['fallbackPolicyPass'] as bool? ?? false;
    final iosMirrorNotePass = stringMap['iosMirrorNotePass'] as bool? ?? false;

    final avcSupported =
        stringMap['avcSupported'] as bool? ??
        (probe['avcSupported'] as bool? ?? false);
    final hevcSupported =
        stringMap['hevcSupported'] as bool? ??
        (probe['hevcSupported'] as bool? ?? false);
    final av1Supported =
        stringMap['av1Supported'] as bool? ??
        (probe['av1Supported'] as bool? ?? false);

    final androidSdk =
        (stringMap['androidSdk'] as num?)?.toInt() ??
        ((probe['androidSdk'] as num?)?.toInt() ?? 0);

    final serverLadderPolicy =
        stringMap['serverLadderPolicy'] as String? ??
        (probe['serverLadderPolicy'] as String? ?? '');

    final iosMirrorNote =
        stringMap['iosMirrorNote'] as String? ??
        (probe['iosMirrorNote'] as String? ?? '');

    final rawCodecs = stringMap['codecs'] ?? probe['codecs'];
    final codecs = rawCodecs is List
        ? rawCodecs
              .whereType<Map>()
              .map(
                (m) => VGStreamingCodecInfo.fromMap(m.cast<Object?, Object?>()),
              )
              .toList()
        : const <VGStreamingCodecInfo>[];

    final raw = stringMap['raw'] as String? ?? '';

    return VGStreamingCodecCapabilityReport(
      pass: pass,
      phase: phase,
      avcPass: avcPass,
      codecCountPass: codecCountPass,
      fallbackPolicyPass: fallbackPolicyPass,
      iosMirrorNotePass: iosMirrorNotePass,
      avcSupported: avcSupported,
      hevcSupported: hevcSupported,
      av1Supported: av1Supported,
      androidSdk: androidSdk,
      serverLadderPolicy: serverLadderPolicy,
      iosMirrorNote: iosMirrorNote,
      codecs: codecs,
      probe: probe,
      raw: raw,
      diagnostics: stringMap,
    );
  }

  /// Returned when an unexpected error or malformed response occurs.
  factory VGStreamingCodecCapabilityReport.failure(
    String reason, [
    Map<String, Object?>? details,
  ]) => VGStreamingCodecCapabilityReport(
    pass: false,
    phase: 'Phase4C5A',
    avcPass: false,
    codecCountPass: false,
    fallbackPolicyPass: false,
    iosMirrorNotePass: false,
    avcSupported: false,
    hevcSupported: false,
    av1Supported: false,
    androidSdk: 0,
    serverLadderPolicy: '',
    iosMirrorNote: '',
    codecs: const <VGStreamingCodecInfo>[],
    probe: const <String, Object?>{},
    raw: 'status=FAIL;reason=$reason',
    diagnostics: details ?? <String, Object?>{'pass': false, 'error': reason},
  );

  /// Returned when the native plugin is not available (e.g. non-Android or missing plugin).
  factory VGStreamingCodecCapabilityReport.unsupported() =>
      const VGStreamingCodecCapabilityReport(
        pass: false,
        phase: 'unsupported',
        avcPass: false,
        codecCountPass: false,
        fallbackPolicyPass: false,
        iosMirrorNotePass: false,
        avcSupported: false,
        hevcSupported: false,
        av1Supported: false,
        androidSdk: 0,
        serverLadderPolicy: '',
        iosMirrorNote: '',
        codecs: <VGStreamingCodecInfo>[],
        probe: <String, Object?>{},
        raw: 'status=UNSUPPORTED;platform=non-android',
        diagnostics: <String, Object?>{
          'pass': false,
          'phase': 'unsupported',
          'raw': 'status=UNSUPPORTED;platform=non-android',
        },
      );

  /// Convenience getter indicating whether hardware-accelerated HEVC decoding is present.
  bool get hasHardwareHevc => codecs.any(
    (c) =>
        (c.codecKey == 'hevc' || c.mimeType == 'video/hevc') &&
        c.hardwareDecoderPresent,
  );

  /// Convenience getter indicating whether hardware-accelerated AV1 decoding is present.
  bool get hasHardwareAv1 => codecs.any(
    (c) =>
        (c.codecKey == 'av1' || c.mimeType == 'video/av01') &&
        c.hardwareDecoderPresent,
  );

  /// Convenience getter indicating whether telemetry for advanced codecs (HEVC or AV1) is present.
  bool get advancedCodecTelemetryPresent => hevcSupported || av1Supported;

  @override
  String toString() =>
      'VGStreamingCodecCapabilityReport(pass=$pass, phase=$phase, avc=$avcSupported, hevc=$hevcSupported, av1=$av1Supported, sdk=$androidSdk, policy=$serverLadderPolicy)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Public Client
// ─────────────────────────────────────────────────────────────────────────────

/// Public client for inspecting device streaming codec capabilities.
///
/// Wraps native platform diagnostic route `runAndroidDagPhase4C5AStreamingCodecCapabilitySmoke`
/// behind a safe, strongly-typed Dart API.
///
/// Invariants:
/// - Pure metadata inspection via platform codec lists ([MediaCodecList]).
/// - Zero `MediaCodec` allocation or decoding execution.
/// - Zero ExoPlayer or Media3 player instantiation.
/// - Zero network usage.
/// - Zero `Surface`, `Image`, or `HardwareBuffer` allocation.
/// - Safe to import and call on all platforms; returns typed unsupported reports on non-Android.
class VGStreamingCodecCapabilityClient {
  VGStreamingCodecCapabilityClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  /// Probes device codec capabilities across AVC, HEVC, and AV1.
  Future<VGStreamingCodecCapabilityReport> probe() async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C5AStreamingCodecCapabilitySmoke',
      );
      if (raw is! Map) {
        return VGStreamingCodecCapabilityReport.failure(
          'invalid_response:$raw',
        );
      }
      return VGStreamingCodecCapabilityReport.fromMap(
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return VGStreamingCodecCapabilityReport.unsupported();
    } catch (e) {
      return VGStreamingCodecCapabilityReport.failure('exception:$e');
    }
  }
}

Map<String, Object?> _defensiveStringMap(Map<Object?, Object?> map) {
  final result = <String, Object?>{};
  for (final entry in map.entries) {
    final key = entry.key?.toString();
    if (key != null) {
      result[key] = entry.value;
    }
  }
  return result;
}
