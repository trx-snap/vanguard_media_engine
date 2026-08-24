// Copyright (c) Connects — Vanguard Phase 4C5N.
// Public streaming compatibility decision API client.
//
// Safe to import on all platforms: methods catch [MissingPluginException]
// and return typed unsupported results instead of throwing.

import 'dart:async';

import 'package:flutter/services.dart';

import 'vg_streaming_preflight_client.dart';

export 'vg_streaming_playback_client.dart' show VGStreamingFormatHint;
export 'vg_streaming_preflight_client.dart' show VGStreamingManifestSpec;

// ─────────────────────────────────────────────────────────────────────────────
// Request Models
// ─────────────────────────────────────────────────────────────────────────────

/// Request configuration passed to [VGStreamingCompatibilityDecisionClient.evaluate].
class VGStreamingCompatibilityDecisionRequest {
  /// List of candidate manifest specifications to evaluate against device codec capabilities.
  /// Must contain at least one manifest spec.
  final List<VGStreamingManifestSpec> manifests;

  VGStreamingCompatibilityDecisionRequest({required this.manifests})
    : assert(manifests.isNotEmpty, 'manifests must not be empty');

  /// Converts this request to the map argument format expected by native routes.
  Map<String, Object?> toArgs() => <String, Object?>{
    'manifests': manifests.map((m) => m.toArgs()).toList(),
  };

  @override
  String toString() =>
      'VGStreamingCompatibilityDecisionRequest(manifests=${manifests.length})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry Model
// ─────────────────────────────────────────────────────────────────────────────

/// Detailed compatibility decision descriptor for an individual candidate stream.
class VGStreamingCompatibilityDecisionEntry {
  /// Unique identifier key for this stream specification.
  final String key;

  /// Target manifest URI string.
  final String uri;

  /// Format hint guiding manifest inspection (e.g. `'HLS'`, `'DASH'`, or `'AUTO'`).
  final String formatHint;

  /// Whether this candidate stream passed compatibility and safe-codec evaluation.
  final bool pass;

  /// Whether manifest ladder policy validation succeeded for this stream.
  final bool manifestPolicyPass;

  /// Whether AVC/H.264 video renditions are present in the manifest.
  final bool avcManifestPresent;

  /// Whether HEVC/H.265 video renditions are present in the manifest.
  final bool hevcManifestPresent;

  /// Whether AV1 video renditions are present in the manifest.
  final bool av1ManifestPresent;

  /// Whether AVC/H.264 decoding is supported on this device.
  final bool avcDeviceSupported;

  /// Whether HEVC/H.265 decoding is supported on this device.
  final bool hevcDeviceSupported;

  /// Whether AV1 decoding is supported on this device.
  final bool av1DeviceSupported;

  /// Whether hardware-accelerated AVC/H.264 decoding is confirmed.
  final bool avcHardwareSafe;

  /// Whether hardware-accelerated HEVC/H.265 decoding is confirmed.
  final bool hevcHardwareSafe;

  /// Whether hardware-accelerated AV1 decoding is confirmed.
  final bool av1HardwareSafe;

  /// Preferred codec family selected for this stream (e.g. `'av1'`, `'hevc'`, `'avc'`, `'none'`).
  final String preferredCodecFamily;

  /// Baseline fallback codec family (e.g. `'avc'` or `'none'`).
  final String fallbackCodecFamily;

  /// Codec families deemed safe for playback on this device (e.g. `['avc']`).
  final List<String> safeCodecFamilies;

  /// Codec families present in manifest but lacking hardware support or device viability.
  final List<String> riskyCodecFamilies;

  /// Specific diagnostic warnings encountered for this stream.
  final List<String> warnings;

  /// Total number of variants or representations available in the manifest ladder.
  final int renditionCount;

  /// Lowest bandwidth ladder variant in bits per second (bps).
  final int lowestBandwidth;

  /// Highest bandwidth ladder variant in bits per second (bps).
  final int highestBandwidth;

  /// Evaluated decision code (e.g. `'prefer_av1_hardware'`, `'prefer_hevc_hardware'`,
  /// `'prefer_avc_fallback'`, `'blocked_no_safe_codec'`, `'blocked_manifest_policy_failed'`).
  final String decision;

  /// Raw diagnostic status string for this entry.
  final String raw;

  /// Underlying manifest validation dictionary from native validator.
  final Map<String, Object?> manifestValidation;

  /// Complete diagnostic dictionary for this entry.
  final Map<String, Object?> diagnostics;

  const VGStreamingCompatibilityDecisionEntry({
    required this.key,
    required this.uri,
    required this.formatHint,
    required this.pass,
    required this.manifestPolicyPass,
    required this.avcManifestPresent,
    required this.hevcManifestPresent,
    required this.av1ManifestPresent,
    required this.avcDeviceSupported,
    required this.hevcDeviceSupported,
    required this.av1DeviceSupported,
    required this.avcHardwareSafe,
    required this.hevcHardwareSafe,
    required this.av1HardwareSafe,
    required this.preferredCodecFamily,
    required this.fallbackCodecFamily,
    required this.safeCodecFamilies,
    required this.riskyCodecFamilies,
    required this.warnings,
    required this.renditionCount,
    required this.lowestBandwidth,
    required this.highestBandwidth,
    required this.decision,
    required this.raw,
    required this.manifestValidation,
    required this.diagnostics,
  });

  /// Constructs a [VGStreamingCompatibilityDecisionEntry] defensively from a platform dictionary.
  factory VGStreamingCompatibilityDecisionEntry.fromMap(
    Map<Object?, Object?> map,
  ) {
    final stringMap = _defensiveStringMap(map);

    final key = stringMap['key'] as String? ?? '';
    final uri = stringMap['uri'] as String? ?? '';
    final formatHint = stringMap['formatHint'] as String? ?? 'AUTO';
    final pass = stringMap['pass'] as bool? ?? false;
    final manifestPolicyPass =
        stringMap['manifestPolicyPass'] as bool? ?? false;
    final avcManifestPresent =
        stringMap['avcManifestPresent'] as bool? ?? false;
    final hevcManifestPresent =
        stringMap['hevcManifestPresent'] as bool? ?? false;
    final av1ManifestPresent =
        stringMap['av1ManifestPresent'] as bool? ?? false;
    final avcDeviceSupported =
        stringMap['avcDeviceSupported'] as bool? ?? false;
    final hevcDeviceSupported =
        stringMap['hevcDeviceSupported'] as bool? ?? false;
    final av1DeviceSupported =
        stringMap['av1DeviceSupported'] as bool? ?? false;
    final avcHardwareSafe = stringMap['avcHardwareSafe'] as bool? ?? false;
    final hevcHardwareSafe = stringMap['hevcHardwareSafe'] as bool? ?? false;
    final av1HardwareSafe = stringMap['av1HardwareSafe'] as bool? ?? false;
    final preferredCodecFamily =
        stringMap['preferredCodecFamily'] as String? ?? 'none';
    final fallbackCodecFamily =
        stringMap['fallbackCodecFamily'] as String? ?? 'none';

    final rawSafe = stringMap['safeCodecFamilies'];
    final safeCodecFamilies = rawSafe is List
        ? rawSafe
              .map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList()
        : const <String>[];

    final rawRisky = stringMap['riskyCodecFamilies'];
    final riskyCodecFamilies = rawRisky is List
        ? rawRisky
              .map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList()
        : const <String>[];

    final rawWarn = stringMap['warnings'];
    final warnings = rawWarn is List
        ? rawWarn
              .map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList()
        : const <String>[];

    final renditionCount = (stringMap['renditionCount'] as num?)?.toInt() ?? 0;
    final lowestBandwidth =
        (stringMap['lowestBandwidth'] as num?)?.toInt() ?? 0;
    final highestBandwidth =
        (stringMap['highestBandwidth'] as num?)?.toInt() ?? 0;
    final decision = stringMap['decision'] as String? ?? '';
    final raw = stringMap['raw'] as String? ?? '';

    final rawValidation = stringMap['manifestValidation'];
    final manifestValidation = rawValidation is Map
        ? _defensiveStringMap(rawValidation.cast<Object?, Object?>())
        : const <String, Object?>{};

    return VGStreamingCompatibilityDecisionEntry(
      key: key,
      uri: uri,
      formatHint: formatHint,
      pass: pass,
      manifestPolicyPass: manifestPolicyPass,
      avcManifestPresent: avcManifestPresent,
      hevcManifestPresent: hevcManifestPresent,
      av1ManifestPresent: av1ManifestPresent,
      avcDeviceSupported: avcDeviceSupported,
      hevcDeviceSupported: hevcDeviceSupported,
      av1DeviceSupported: av1DeviceSupported,
      avcHardwareSafe: avcHardwareSafe,
      hevcHardwareSafe: hevcHardwareSafe,
      av1HardwareSafe: av1HardwareSafe,
      preferredCodecFamily: preferredCodecFamily,
      fallbackCodecFamily: fallbackCodecFamily,
      safeCodecFamilies: safeCodecFamilies,
      riskyCodecFamilies: riskyCodecFamilies,
      warnings: warnings,
      renditionCount: renditionCount,
      lowestBandwidth: lowestBandwidth,
      highestBandwidth: highestBandwidth,
      decision: decision,
      raw: raw,
      manifestValidation: manifestValidation,
      diagnostics: stringMap,
    );
  }

  /// Convenience getter indicating whether this stream decision is blocked.
  bool get blocked => decision.startsWith('blocked_');

  /// Convenience getter indicating whether this stream prefers AVC/H.264 fallback.
  bool get prefersAvcFallback => decision == 'prefer_avc_fallback';

  /// Convenience getter indicating whether this stream prefers a hardware-accelerated advanced codec (HEVC or AV1).
  bool get prefersHardwareAdvancedCodec =>
      decision == 'prefer_av1_hardware' || decision == 'prefer_hevc_hardware';

  @override
  String toString() =>
      'VGStreamingCompatibilityDecisionEntry(key=$key, pass=$pass, decision=$decision, preferred=$preferredCodecFamily, fallback=$fallbackCodecFamily, renditions=$renditionCount)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Aggregate Report Model
// ─────────────────────────────────────────────────────────────────────────────

/// Structured compatibility decision report returned by [VGStreamingCompatibilityDecisionClient.evaluate].
///
/// Unifies device codec capability diagnostics with host manifest policy validation to produce
/// deterministic, hardware-safe codec decisions across candidate streaming manifests.
class VGStreamingCompatibilityDecisionReport {
  /// Whether overall compatibility verification passed across all candidate streams.
  final bool pass;

  /// Platform engine phase identifier (e.g. `"Phase4C5E"` or `"unsupported"`).
  final String phase;

  /// Total number of stream manifest specifications inspected and evaluated.
  final int totalReports;

  /// Total number of stream specifications that passed compatibility evaluation.
  final int passedReports;

  /// Total number of stream specifications that failed compatibility evaluation.
  final int failedReports;

  /// Whether underlying codec capability probing succeeded.
  final bool codecProbePass;

  /// Whether baseline AVC/H.264 decoder support is confirmed on device.
  final bool avcSupported;

  /// Whether HEVC/H.265 decoder support is confirmed on device.
  final bool hevcSupported;

  /// Whether AV1 decoder support is confirmed on device.
  final bool av1Supported;

  /// Whether hardware-accelerated AV1 decoding is confirmed on device.
  final bool av1HardwareSafe;

  /// Device-level hardware/software codec warnings (e.g. `['av1_software_only']`).
  final List<String> deviceWarnings;

  /// Server ladder policy requirement string (e.g. `"add_hevc_av1_renditions_but_keep_avc_fallback"`).
  final String serverLadderPolicy;

  /// Guidance note for iOS mirror implementations.
  final String iosMirrorNote;

  /// Individual per-manifest compatibility decision entries.
  final List<VGStreamingCompatibilityDecisionEntry> reports;

  /// Raw diagnostic summary string from native platform engine.
  final String raw;

  /// Complete diagnostic telemetry dictionary returned by native platform engine.
  final Map<String, Object?> diagnostics;

  const VGStreamingCompatibilityDecisionReport({
    required this.pass,
    required this.phase,
    required this.totalReports,
    required this.passedReports,
    required this.failedReports,
    required this.codecProbePass,
    required this.avcSupported,
    required this.hevcSupported,
    required this.av1Supported,
    required this.av1HardwareSafe,
    required this.deviceWarnings,
    required this.serverLadderPolicy,
    required this.iosMirrorNote,
    required this.reports,
    required this.raw,
    required this.diagnostics,
  });

  /// Constructs a [VGStreamingCompatibilityDecisionReport] from a raw platform dictionary.
  factory VGStreamingCompatibilityDecisionReport.fromMap(
    Map<Object?, Object?> map,
  ) {
    final stringMap = _defensiveStringMap(map);

    final pass = stringMap['pass'] as bool? ?? false;
    final phase = stringMap['phase'] as String? ?? 'Phase4C5E';
    final totalReports = (stringMap['totalReports'] as num?)?.toInt() ?? 0;
    final passedReports = (stringMap['passedReports'] as num?)?.toInt() ?? 0;
    final failedReports = (stringMap['failedReports'] as num?)?.toInt() ?? 0;
    final codecProbePass = stringMap['codecProbePass'] as bool? ?? false;
    final avcSupported = stringMap['avcSupported'] as bool? ?? false;
    final hevcSupported = stringMap['hevcSupported'] as bool? ?? false;
    final av1Supported = stringMap['av1Supported'] as bool? ?? false;
    final av1HardwareSafe = stringMap['av1HardwareSafe'] as bool? ?? false;

    final rawDeviceWarnings = stringMap['deviceWarnings'];
    final deviceWarnings = rawDeviceWarnings is List
        ? rawDeviceWarnings
              .map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList()
        : const <String>[];

    final serverLadderPolicy = stringMap['serverLadderPolicy'] as String? ?? '';
    final iosMirrorNote = stringMap['iosMirrorNote'] as String? ?? '';

    final rawReports = stringMap['reports'];
    final reports = rawReports is List
        ? rawReports
              .whereType<Map>()
              .map(
                (m) => VGStreamingCompatibilityDecisionEntry.fromMap(
                  m.cast<Object?, Object?>(),
                ),
              )
              .toList()
        : const <VGStreamingCompatibilityDecisionEntry>[];

    final raw = stringMap['raw'] as String? ?? '';

    return VGStreamingCompatibilityDecisionReport(
      pass: pass,
      phase: phase,
      totalReports: totalReports,
      passedReports: passedReports,
      failedReports: failedReports,
      codecProbePass: codecProbePass,
      avcSupported: avcSupported,
      hevcSupported: hevcSupported,
      av1Supported: av1Supported,
      av1HardwareSafe: av1HardwareSafe,
      deviceWarnings: deviceWarnings,
      serverLadderPolicy: serverLadderPolicy,
      iosMirrorNote: iosMirrorNote,
      reports: reports,
      raw: raw,
      diagnostics: stringMap,
    );
  }

  /// Returned when an unexpected error or malformed response occurs.
  factory VGStreamingCompatibilityDecisionReport.failure(
    String reason, [
    Map<String, Object?>? details,
  ]) => VGStreamingCompatibilityDecisionReport(
    pass: false,
    phase: 'Phase4C5E',
    totalReports: 0,
    passedReports: 0,
    failedReports: 0,
    codecProbePass: false,
    avcSupported: false,
    hevcSupported: false,
    av1Supported: false,
    av1HardwareSafe: false,
    deviceWarnings: const <String>[],
    serverLadderPolicy: '',
    iosMirrorNote: '',
    reports: const <VGStreamingCompatibilityDecisionEntry>[],
    raw: 'status=FAIL;reason=$reason',
    diagnostics: details ?? <String, Object?>{'pass': false, 'error': reason},
  );

  /// Returned when the native plugin is not available (e.g. non-Android or missing plugin).
  factory VGStreamingCompatibilityDecisionReport.unsupported() =>
      const VGStreamingCompatibilityDecisionReport(
        pass: false,
        phase: 'unsupported',
        totalReports: 0,
        passedReports: 0,
        failedReports: 0,
        codecProbePass: false,
        avcSupported: false,
        hevcSupported: false,
        av1Supported: false,
        av1HardwareSafe: false,
        deviceWarnings: <String>[],
        serverLadderPolicy: '',
        iosMirrorNote: '',
        reports: <VGStreamingCompatibilityDecisionEntry>[],
        raw: 'status=UNSUPPORTED;platform=non-android',
        diagnostics: <String, Object?>{
          'pass': false,
          'phase': 'unsupported',
          'raw': 'status=UNSUPPORTED;platform=non-android',
        },
      );

  /// Convenience getter indicating whether all evaluated reports passed.
  bool get allReportsPass => totalReports > 0 && failedReports == 0;

  /// Convenience getter indicating whether device-level warnings are present.
  bool get hasDeviceWarnings => deviceWarnings.isNotEmpty;

  /// Convenience getter indicating whether AV1 is supported on device via software-only decoding.
  bool get av1SoftwareOnly =>
      deviceWarnings.contains('av1_software_only') ||
      (av1Supported && !av1HardwareSafe);

  @override
  String toString() =>
      'VGStreamingCompatibilityDecisionReport(pass=$pass, phase=$phase, '
      'total=$totalReports, passed=$passedReports, failed=$failedReports, '
      'probePass=$codecProbePass, avc=$avcSupported, hevc=$hevcSupported, av1=$av1Supported, '
      'av1HwSafe=$av1HardwareSafe, policy=$serverLadderPolicy)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Public Client
// ─────────────────────────────────────────────────────────────────────────────

/// Public client for evaluating streaming compatibility decisions across device decoders
/// and manifest rendition ladders.
///
/// Wraps native platform diagnostic route `runAndroidDagPhase4C5ECompatibilityDecisionSmoke`
/// behind a safe, strongly-typed Dart API.
///
/// Invariants:
/// - Diagnostic decision brain: joins device decoder capability diagnostics with manifest policy checks.
/// - Zero `ExoPlayer` or `Media3` player allocation.
/// - Zero `MediaCodec` decoding execution.
/// - Zero segment downloading, zero `Surface` / `ImageReader` / `HardwareBuffer` creation.
/// - Zero playback mutation, zero ABR or track selection forcing.
/// - Safe to import and call on all platforms; returns typed unsupported reports on non-Android.
class VGStreamingCompatibilityDecisionClient {
  VGStreamingCompatibilityDecisionClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  /// Evaluates host-supplied streaming manifest specs against device codec capabilities,
  /// returning an authoritative compatibility decision report.
  Future<VGStreamingCompatibilityDecisionReport> evaluate(
    VGStreamingCompatibilityDecisionRequest request,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C5ECompatibilityDecisionSmoke',
        request.toArgs(),
      );
      if (raw is! Map) {
        return VGStreamingCompatibilityDecisionReport.failure(
          'invalid_response:$raw',
        );
      }
      return VGStreamingCompatibilityDecisionReport.fromMap(
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return VGStreamingCompatibilityDecisionReport.unsupported();
    } catch (e) {
      return VGStreamingCompatibilityDecisionReport.failure('exception:$e');
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
