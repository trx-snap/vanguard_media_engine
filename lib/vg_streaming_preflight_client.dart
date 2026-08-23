// Copyright (c) Connects — Vanguard Phase 4C7E.
// Public streaming preflight advisory API client.
//
// Safe to import on all platforms: methods catch [MissingPluginException]
// and return typed unsupported results instead of throwing.

import 'dart:async';

import 'package:flutter/services.dart';

import 'vg_streaming_playback_client.dart';

export 'vg_streaming_playback_client.dart'
    show VGStreamingFormatHint, VGStreamingNetworkProfile;

// ─────────────────────────────────────────────────────────────────────────────
// Value objects & Manifest specifications
// ─────────────────────────────────────────────────────────────────────────────

/// Specification for a candidate streaming manifest evaluated by the preflight engine.
class VGStreamingManifestSpec {
  /// Unique caller-defined identifier for this manifest spec (e.g. `"mux_hls_test"`).
  final String key;

  /// HTTP/HTTPS URI to the multivariant master playlist or DASH MPD.
  final Uri uri;

  /// Format hint guiding manifest inspection (defaults to [VGStreamingFormatHint.auto]).
  final VGStreamingFormatHint formatHint;

  /// Whether the stream requires an adaptive multi-bitrate ladder (defaults to `true`).
  final bool requireAdaptiveLadder;

  /// Whether modern codec renditions (HEVC/AV1) must include an AVC/H.264 fallback (defaults to `true`).
  final bool requireAvcFallback;

  /// Whether low-latency tags (LL-HLS partial segments/preload hints) are strictly required (defaults to `false`).
  final bool requireLlHlsTags;

  /// Whether single-rendition media playlists are allowed as valid ladders (defaults to `false`).
  final bool allowMediaPlaylist;

  /// Optional HTTP headers sent when inspecting the manifest (e.g. auth tokens).
  final Map<String, String>? httpHeaders;

  VGStreamingManifestSpec({
    required this.key,
    required this.uri,
    this.formatHint = VGStreamingFormatHint.auto,
    this.requireAdaptiveLadder = true,
    this.requireAvcFallback = true,
    this.requireLlHlsTags = false,
    this.allowMediaPlaylist = false,
    this.httpHeaders,
  }) : assert(key.isNotEmpty, 'key must not be empty');

  /// Converts this specification to the map argument format consumed by the native coordinator.
  Map<String, Object?> toArgs() => <String, Object?>{
    'key': key,
    'uri': uri.toString(),
    'formatHint': formatHint.toNative(),
    'requireAdaptiveLadder': requireAdaptiveLadder,
    'requireAvcFallback': requireAvcFallback,
    'requireLlHlsTags': requireLlHlsTags,
    'allowMediaPlaylist': allowMediaPlaylist,
    if (httpHeaders != null) 'httpHeaders': httpHeaders,
  };
}

/// Request configuration passed to [VGStreamingPreflightClient.evaluate].
class VGStreamingPreflightRequest {
  /// List of candidate manifest specifications to inspect and validate.
  /// Must contain at least one manifest spec.
  final List<VGStreamingManifestSpec> manifests;

  /// Requested network profile guiding policy arbitration (defaults to [VGStreamingNetworkProfile.auto]).
  final VGStreamingNetworkProfile requestedNetworkProfile;

  /// Whether low-latency streaming playback is preferred.
  final bool preferLowLatency;

  /// Whether low-latency streaming may be advised even on bandwidth-constrained network profiles.
  final bool allowLowLatencyOnConstrained;

  VGStreamingPreflightRequest({
    required this.manifests,
    this.requestedNetworkProfile = VGStreamingNetworkProfile.auto,
    this.preferLowLatency = false,
    this.allowLowLatencyOnConstrained = false,
  }) : assert(manifests.isNotEmpty, 'manifests must not be empty');

  /// Converts this request to the map argument format expected by native preflight routes.
  Map<String, Object?> toArgs() => <String, Object?>{
    'manifests': manifests.map((m) => m.toArgs()).toList(),
    'requestedNetworkProfile': requestedNetworkProfile.toNative(),
    'preferLowLatency': preferLowLatency,
    'allowLowLatencyOnConstrained': allowLowLatencyOnConstrained,
  };
}

/// Structured preflight advisory report returned by [VGStreamingPreflightClient.evaluate].
///
/// Advises the host application on stream compatibility, decoder viability,
/// and recommended network policies before initiating playback.
class VGStreamingPreflightReport {
  /// Whether all inspected streams and device codec capabilities passed validation.
  final bool pass;

  /// Platform engine phase identifier (e.g. `"Phase4C5G"`).
  final String phase;

  /// High-level advisory decision code (e.g. `"advise_constrained"`, `"advise_low_latency"`, `"advise_stable"`).
  final String advisoryDecision;

  /// String representation of the requested network profile (e.g. `"AUTO"`, `"CONSTRAINED"`).
  final String requestedNetworkProfile;

  /// String representation of the recommended network profile (e.g. `"CONSTRAINED"`, `"STABLE"`, `"LOW_LATENCY"`).
  final String recommendedNetworkProfile;

  /// Detailed network policy parameter map recommended for subsequent playback.
  final Map<String, Object?> recommendedNetworkPolicy;

  /// Total number of stream manifest specifications inspected.
  final int totalReports;

  /// Total number of stream specifications that passed compatibility validation.
  final int passedReports;

  /// Total number of stream specifications that failed compatibility validation.
  final int failedReports;

  /// Advisory-level warnings encountered during evaluation.
  final List<String> warnings;

  /// Device hardware/software codec warnings (e.g. `["av1_software_only"]`).
  final List<String> deviceWarnings;

  /// Whether at least one inspected manifest supports Apple LL-HLS tags.
  final bool llHlsAvailable;

  /// Confirmation invariant: always `true` (pure advisory with zero player allocation).
  final bool advisoryOnly;

  /// Confirmation invariant: always `false` (zero playback mutation).
  final bool playbackMutation;

  /// Server ladder policy requirement string.
  final String serverLadderPolicy;

  /// Guidance note for iOS mirror implementations.
  final String iosMirrorNote;

  /// Raw diagnostic summary string.
  final String raw;

  /// Diagnostic telemetry key-value dictionary.
  final Map<String, Object?> diagnostics;

  const VGStreamingPreflightReport({
    required this.pass,
    required this.phase,
    required this.advisoryDecision,
    required this.requestedNetworkProfile,
    required this.recommendedNetworkProfile,
    required this.recommendedNetworkPolicy,
    required this.totalReports,
    required this.passedReports,
    required this.failedReports,
    required this.warnings,
    required this.deviceWarnings,
    required this.llHlsAvailable,
    required this.advisoryOnly,
    required this.playbackMutation,
    required this.serverLadderPolicy,
    required this.iosMirrorNote,
    required this.raw,
    required this.diagnostics,
  });

  /// Constructs a [VGStreamingPreflightReport] from a raw platform dictionary.
  factory VGStreamingPreflightReport.fromMap(Map<Object?, Object?> map) {
    final stringMap = _defensiveStringMap(map);

    final pass = stringMap['pass'] as bool? ?? false;
    final phase = stringMap['phase'] as String? ?? 'Phase4C5G';
    final advisoryDecision = stringMap['advisoryDecision'] as String? ?? '';
    final requestedNetworkProfile =
        stringMap['requestedNetworkProfile'] as String? ?? '';
    final recommendedNetworkProfile =
        stringMap['recommendedNetworkProfile'] as String? ?? '';

    final rawPolicy = stringMap['recommendedNetworkPolicy'];
    final recommendedNetworkPolicy = rawPolicy is Map
        ? _defensiveStringMap(rawPolicy.cast<Object?, Object?>())
        : const <String, Object?>{};

    final totalReports = (stringMap['totalReports'] as num?)?.toInt() ?? 0;
    final passedReports = (stringMap['passedReports'] as num?)?.toInt() ?? 0;
    final failedReports = (stringMap['failedReports'] as num?)?.toInt() ?? 0;

    final warnings =
        (stringMap['warnings'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    final deviceWarnings =
        (stringMap['deviceWarnings'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];

    final llHlsAvailable = stringMap['llHlsAvailable'] as bool? ?? false;
    final advisoryOnly = stringMap['advisoryOnly'] as bool? ?? true;
    final playbackMutation = stringMap['playbackMutation'] as bool? ?? false;
    final serverLadderPolicy = stringMap['serverLadderPolicy'] as String? ?? '';
    final iosMirrorNote = stringMap['iosMirrorNote'] as String? ?? '';
    final raw = stringMap['raw'] as String? ?? '';

    return VGStreamingPreflightReport(
      pass: pass,
      phase: phase,
      advisoryDecision: advisoryDecision,
      requestedNetworkProfile: requestedNetworkProfile,
      recommendedNetworkProfile: recommendedNetworkProfile,
      recommendedNetworkPolicy: recommendedNetworkPolicy,
      totalReports: totalReports,
      passedReports: passedReports,
      failedReports: failedReports,
      warnings: warnings,
      deviceWarnings: deviceWarnings,
      llHlsAvailable: llHlsAvailable,
      advisoryOnly: advisoryOnly,
      playbackMutation: playbackMutation,
      serverLadderPolicy: serverLadderPolicy,
      iosMirrorNote: iosMirrorNote,
      raw: raw,
      diagnostics: stringMap,
    );
  }

  /// Returned when the native plugin is not available (e.g. non-Android or missing plugin).
  factory VGStreamingPreflightReport.unsupported() =>
      const VGStreamingPreflightReport(
        pass: false,
        phase: 'unsupported',
        advisoryDecision: 'unsupported',
        requestedNetworkProfile: 'AUTO',
        recommendedNetworkProfile: 'CONSTRAINED',
        recommendedNetworkPolicy: <String, Object?>{
          'profile': 'CONSTRAINED',
          'pass': false,
        },
        totalReports: 0,
        passedReports: 0,
        failedReports: 0,
        warnings: <String>['unsupported_platform'],
        deviceWarnings: <String>[],
        llHlsAvailable: false,
        advisoryOnly: true,
        playbackMutation: false,
        serverLadderPolicy: '',
        iosMirrorNote: '',
        raw: 'status=UNSUPPORTED;platform=non-android',
        diagnostics: <String, Object?>{
          'pass': false,
          'phase': 'unsupported',
          'raw': 'status=UNSUPPORTED;platform=non-android',
        },
      );

  static Map<String, Object?> _defensiveStringMap(Map<Object?, Object?> map) {
    final result = <String, Object?>{};
    for (final entry in map.entries) {
      final key = entry.key?.toString();
      if (key != null) {
        result[key] = entry.value;
      }
    }
    return result;
  }

  @override
  String toString() =>
      'VGStreamingPreflightReport(pass=$pass, phase=$phase, '
      'decision=$advisoryDecision, recommended=$recommendedNetworkProfile, '
      'totalReports=$totalReports, passedReports=$passedReports, failedReports=$failedReports)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Public client
// ─────────────────────────────────────────────────────────────────────────────

/// Public client for Vanguard adaptive streaming preflight advisory evaluations.
///
/// Encapsulates platform `MethodChannel` interaction, manifest specification
/// serialization, and error translation.
///
/// Pure diagnostic advisory: does not instantiate ExoPlayer, MediaCodec, Surface,
/// ImageReader, HardwareBuffer, Vulkan, GLES, DAG renderers, WebRTC, or LiveKit.
class VGStreamingPreflightClient {
  VGStreamingPreflightClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  /// Evaluates host-supplied streaming manifest specs against device codec capabilities
  /// and network profile policies, returning an advisory report.
  Future<VGStreamingPreflightReport> evaluate(
    VGStreamingPreflightRequest request,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'evaluateStreamingPreflightAdvisory',
        request.toArgs(),
      );
      if (raw is! Map) {
        return VGStreamingPreflightReport.unsupported();
      }
      return VGStreamingPreflightReport.fromMap(raw.cast<Object?, Object?>());
    } on MissingPluginException {
      return VGStreamingPreflightReport.unsupported();
    }
  }
}
