// Copyright (c) Connects — Vanguard Phase 4C5H.
// Public streaming manifest policy validation API client.
//
// Safe to import on all platforms: methods catch [MissingPluginException]
// and return typed unsupported results instead of throwing.

import 'dart:async';

import 'package:flutter/services.dart';

import 'vg_streaming_playback_client.dart';
import 'vg_streaming_preflight_client.dart';

export 'vg_streaming_playback_client.dart' show VGStreamingFormatHint;
export 'vg_streaming_preflight_client.dart' show VGStreamingManifestSpec;

// ─────────────────────────────────────────────────────────────────────────────
// Request Models
// ─────────────────────────────────────────────────────────────────────────────

/// Request configuration passed to [VGStreamingManifestPolicyClient.validate].
class VGStreamingManifestPolicyValidationRequest {
  /// List of candidate manifest specifications to validate against ladder policy.
  /// Must contain at least one manifest spec.
  final List<VGStreamingManifestSpec> manifests;

  VGStreamingManifestPolicyValidationRequest({required this.manifests})
    : assert(manifests.isNotEmpty, 'manifests must not be empty');

  /// Converts this request to the map argument format expected by native manifest policy routes.
  Map<String, Object?> toArgs() => <String, Object?>{
    'manifests': manifests.map((m) => m.toArgs()).toList(),
  };

  @override
  String toString() =>
      'VGStreamingManifestPolicyValidationRequest(manifests=${manifests.length})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Report Models
// ─────────────────────────────────────────────────────────────────────────────

/// Structured manifest policy validation report returned by [VGStreamingManifestPolicyClient.validate].
///
/// Confirms whether candidate manifests satisfy server ladder policies, AVC fallback
/// requirements, format restrictions, and pre-fetch segment rejection assertions.
class VGStreamingManifestPolicyValidationReport {
  /// Whether all inspected manifests satisfied ladder policy and passed segment rejection.
  final bool pass;

  /// Platform engine phase identifier (e.g. `"Phase4C5D"` or `"unsupported"`).
  final String phase;

  /// Total number of stream manifest specifications inspected and validated.
  final int totalManifestsValidated;

  /// Total number of stream specifications that passed ladder policy validation.
  final int passedManifests;

  /// Total number of stream specifications that failed ladder policy validation.
  final int failedManifests;

  /// Whether internal security assertion for media segment URL rejection succeeded.
  final bool segmentRejectionPass;

  /// Server ladder policy requirement string (e.g. `"add_hevc_av1_renditions_but_keep_avc_fallback"`).
  final String serverLadderPolicy;

  /// Guidance note for iOS mirror implementations.
  final String iosMirrorNote;

  /// Individual per-manifest validation results.
  final List<Map<String, Object?>> results;

  /// Diagnostic result of the segment rejection assertion.
  final Map<String, Object?> segmentRejectionResult;

  /// Raw diagnostic summary string from native platform engine.
  final String raw;

  /// Complete diagnostic telemetry dictionary returned by native platform engine.
  final Map<String, Object?> diagnostics;

  const VGStreamingManifestPolicyValidationReport({
    required this.pass,
    required this.phase,
    required this.totalManifestsValidated,
    required this.passedManifests,
    required this.failedManifests,
    required this.segmentRejectionPass,
    required this.serverLadderPolicy,
    required this.iosMirrorNote,
    required this.results,
    required this.segmentRejectionResult,
    required this.raw,
    required this.diagnostics,
  });

  /// Constructs a [VGStreamingManifestPolicyValidationReport] from a raw platform dictionary.
  factory VGStreamingManifestPolicyValidationReport.fromMap(
    Map<Object?, Object?> map,
  ) {
    final stringMap = _defensiveStringMap(map);

    final pass = stringMap['pass'] as bool? ?? false;
    final phase = stringMap['phase'] as String? ?? 'Phase4C5D';
    final totalManifestsValidated =
        (stringMap['totalManifestsValidated'] as num?)?.toInt() ?? 0;
    final passedManifests =
        (stringMap['passedManifests'] as num?)?.toInt() ?? 0;
    final failedManifests =
        (stringMap['failedManifests'] as num?)?.toInt() ?? 0;
    final segmentRejectionPass =
        stringMap['segmentRejectionPass'] as bool? ?? false;
    final serverLadderPolicy = stringMap['serverLadderPolicy'] as String? ?? '';
    final iosMirrorNote = stringMap['iosMirrorNote'] as String? ?? '';

    final rawResults = stringMap['results'];
    final results = rawResults is List
        ? rawResults
              .whereType<Map>()
              .map((m) => _defensiveStringMap(m.cast<Object?, Object?>()))
              .toList()
        : const <Map<String, Object?>>[];

    final rawSeg = stringMap['segmentRejectionResult'];
    final segmentRejectionResult = rawSeg is Map
        ? _defensiveStringMap(rawSeg.cast<Object?, Object?>())
        : const <String, Object?>{};

    final raw = stringMap['raw'] as String? ?? '';

    return VGStreamingManifestPolicyValidationReport(
      pass: pass,
      phase: phase,
      totalManifestsValidated: totalManifestsValidated,
      passedManifests: passedManifests,
      failedManifests: failedManifests,
      segmentRejectionPass: segmentRejectionPass,
      serverLadderPolicy: serverLadderPolicy,
      iosMirrorNote: iosMirrorNote,
      results: results,
      segmentRejectionResult: segmentRejectionResult,
      raw: raw,
      diagnostics: stringMap,
    );
  }

  /// Returned when an unexpected error or malformed response occurs.
  factory VGStreamingManifestPolicyValidationReport.failure(
    String reason, [
    Map<String, Object?>? details,
  ]) {
    return VGStreamingManifestPolicyValidationReport(
      pass: false,
      phase: 'Phase4C5D',
      totalManifestsValidated: 0,
      passedManifests: 0,
      failedManifests: 0,
      segmentRejectionPass: false,
      serverLadderPolicy: '',
      iosMirrorNote: '',
      results: const <Map<String, Object?>>[],
      segmentRejectionResult: const <String, Object?>{},
      raw: 'status=FAIL;reason=$reason',
      diagnostics: details ?? <String, Object?>{'pass': false, 'error': reason},
    );
  }

  /// Returned when the native plugin is not available (e.g. non-Android or missing plugin).
  factory VGStreamingManifestPolicyValidationReport.unsupported() =>
      const VGStreamingManifestPolicyValidationReport(
        pass: false,
        phase: 'unsupported',
        totalManifestsValidated: 0,
        passedManifests: 0,
        failedManifests: 0,
        segmentRejectionPass: false,
        serverLadderPolicy: '',
        iosMirrorNote: '',
        results: <Map<String, Object?>>[],
        segmentRejectionResult: <String, Object?>{},
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
      'VGStreamingManifestPolicyValidationReport(pass=$pass, phase=$phase, '
      'total=$totalManifestsValidated, passed=$passedManifests, failed=$failedManifests, '
      'segmentRejectionPass=$segmentRejectionPass, policy=$serverLadderPolicy)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Public Client
// ─────────────────────────────────────────────────────────────────────────────

/// Public client for Vanguard streaming manifest policy validation.
///
/// Dispatches candidate manifest specifications to the native coordinator to verify
/// multivariant ladder compliance, modern codec AVC fallback invariants, format constraints,
/// and media segment URL rejection security assertions before initiating playback.
///
/// Manifest-only validation: zero ExoPlayer allocation, zero MediaCodec decoding,
/// zero segment downloading, and zero ABR mutation.
class VGStreamingManifestPolicyClient {
  VGStreamingManifestPolicyClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  final MethodChannel _channel;

  /// Validates host-supplied streaming manifest specs against Vanguard ladder policy
  /// and segment rejection assertions.
  Future<VGStreamingManifestPolicyValidationReport> validate(
    VGStreamingManifestPolicyValidationRequest request,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C5DManifestPolicyValidation',
        request.toArgs(),
      );
      if (raw is! Map) {
        return VGStreamingManifestPolicyValidationReport.failure(
          'invalid_response:$raw',
        );
      }
      return VGStreamingManifestPolicyValidationReport.fromMap(
        raw.cast<Object?, Object?>(),
      );
    } on MissingPluginException {
      return VGStreamingManifestPolicyValidationReport.unsupported();
    } catch (e) {
      return VGStreamingManifestPolicyValidationReport.failure('exception:$e');
    }
  }
}
