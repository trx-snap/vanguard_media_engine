// Copyright (c) Connects — Vanguard Phase 4C3Y.
// Public package-level RTC video diagnostics API client for Android True-DAG backend.
//
// Invariants:
// - Video Only: Vanguard RTC operates strictly on video transport contracts.
//   Zero ownership of room signaling, tokens, participant rosters, audio streams,
//   or microphone routing.
// - Transport Agnostic: Concrete WebRTC/LiveKit bridging is product-level;
//   Vanguard core contains zero LiveKit or WebRTC SDK dependencies.
// - Diagnostic Only: Wraps native MethodChannel diagnostic routes.
// - Safe to import on non-Android platforms: catches MissingPluginException and
//   returns typed unsupported results without crashing.

import 'dart:async';

import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Request Models
// ─────────────────────────────────────────────────────────────────────────────

/// Request configuration for [VGRtcVideoDiagnosticsClient.runAll] and focused checks.
class VGRtcVideoDiagnosticsRequest {
  /// Target synthetic frame width in pixels (must be positive).
  final int width;

  /// Target synthetic frame height in pixels (must be positive).
  final int height;

  /// Number of synthetic frames to process in multi-frame checks (must be positive).
  final int frameCount;

  const VGRtcVideoDiagnosticsRequest({
    this.width = 64,
    this.height = 64,
    this.frameCount = 3,
  }) : assert(width > 0, 'width must be positive'),
       assert(height > 0, 'height must be positive'),
       assert(frameCount > 0, 'frameCount must be positive');

  Map<String, dynamic> toMap() => {
    'width': width,
    'height': height,
    'frameCount': frameCount,
  };

  @override
  String toString() =>
      'VGRtcVideoDiagnosticsRequest(width=$width, height=$height, frameCount=$frameCount)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Result Models
// ─────────────────────────────────────────────────────────────────────────────

/// Individual diagnostic check result from an RTC MethodChannel route.
class VGRtcVideoDiagnosticsCheckResult {
  /// Key identifier for the check (e.g. 'contract', 'adapter', 'metadata').
  final String key;

  /// Whether the individual check succeeded.
  final bool pass;

  /// Raw diagnostic summary string from native.
  final String raw;

  /// Complete details map returned by native.
  final Map<String, dynamic> details;

  const VGRtcVideoDiagnosticsCheckResult({
    required this.key,
    required this.pass,
    required this.raw,
    this.details = const <String, dynamic>{},
  });

  factory VGRtcVideoDiagnosticsCheckResult.fromMap(
    String key,
    Map<dynamic, dynamic>? map,
  ) {
    if (map == null) {
      return VGRtcVideoDiagnosticsCheckResult(
        key: key,
        pass: false,
        raw: 'status=FAIL;reason=null_response',
        details: const {},
      );
    }
    final details = Map<String, dynamic>.from(map);
    final pass = details['pass'] == true;
    final raw =
        details['raw']?.toString() ?? (pass ? 'status=OK' : 'status=FAIL');
    return VGRtcVideoDiagnosticsCheckResult(
      key: key,
      pass: pass,
      raw: raw,
      details: details,
    );
  }

  factory VGRtcVideoDiagnosticsCheckResult.failure(
    String key,
    String reason, [
    Map<String, dynamic>? details,
  ]) {
    return VGRtcVideoDiagnosticsCheckResult(
      key: key,
      pass: false,
      raw: 'status=FAIL;reason=$reason',
      details: details ?? {'pass': false, 'error': reason},
    );
  }

  factory VGRtcVideoDiagnosticsCheckResult.unsupported(String key) =>
      VGRtcVideoDiagnosticsCheckResult(
        key: key,
        pass: false,
        raw: 'status=UNSUPPORTED;platform=non-android',
        details: const {'pass': false, 'reason': 'unsupported_platform'},
      );

  Map<String, dynamic> toMap() => {
    'key': key,
    'pass': pass,
    'raw': raw,
    'details': details,
  };

  @override
  String toString() =>
      'VGRtcVideoDiagnosticsCheckResult(key=$key, pass=$pass, raw=$raw)';
}

/// Comprehensive report aggregating all seven Android RTC diagnostic routes.
class VGRtcVideoDiagnosticsReport {
  /// Diagnostic phase identifier (e.g. 'Phase4C3Y' or 'unsupported').
  final String phase;

  /// Whether all seven RTC checks passed.
  final bool pass;

  /// Invariant assertion: Vanguard RTC video remains strictly video-only.
  final bool videoOnlyBoundaryPreserved;

  /// Invariant assertion: Room orchestration & audio streams are strictly excluded from Vanguard.
  final bool roomAudioBoundaryPreserved;

  /// Invariant assertion: Transport contracts remain generic without LiveKit/WebRTC SDK coupling.
  final bool transportAgnostic;

  /// Per-check results keyed by check name ('contract', 'adapter', 'metadata', etc.).
  final Map<String, VGRtcVideoDiagnosticsCheckResult> checks;

  /// Overall raw status summary string.
  final String raw;

  /// Telemetry and structured diagnostic map.
  final Map<String, dynamic> diagnostics;

  const VGRtcVideoDiagnosticsReport({
    this.phase = 'Phase4C3Y',
    required this.pass,
    this.videoOnlyBoundaryPreserved = true,
    this.roomAudioBoundaryPreserved = true,
    this.transportAgnostic = true,
    required this.checks,
    required this.raw,
    required this.diagnostics,
  });

  /// Convenience getter for Phase 4C3D RTC contract check.
  VGRtcVideoDiagnosticsCheckResult? get contract => checks['contract'];

  /// Convenience getter for Phase 4C3G realtime video adapter check.
  VGRtcVideoDiagnosticsCheckResult? get adapter => checks['adapter'];

  /// Convenience getter for Phase 4C3K RTC metadata check.
  VGRtcVideoDiagnosticsCheckResult? get metadata => checks['metadata'];

  /// Convenience getter for Phase 4C3N RTC backpressure check.
  VGRtcVideoDiagnosticsCheckResult? get backpressure => checks['backpressure'];

  /// Convenience getter for Phase 4C3Q RTC frame validator check.
  VGRtcVideoDiagnosticsCheckResult? get validator => checks['validator'];

  /// Convenience getter for Phase 4C3U processed video egress check.
  VGRtcVideoDiagnosticsCheckResult? get processedEgress =>
      checks['processedEgress'];

  /// Convenience getter for Phase 4C4B RTC jitter buffer check.
  VGRtcVideoDiagnosticsCheckResult? get jitterBuffer => checks['jitterBuffer'];

  factory VGRtcVideoDiagnosticsReport.unsupported() {
    return const VGRtcVideoDiagnosticsReport(
      phase: 'unsupported',
      pass: false,
      videoOnlyBoundaryPreserved: false,
      roomAudioBoundaryPreserved: false,
      transportAgnostic: false,
      checks: {},
      raw: 'status=UNSUPPORTED;platform=non-android',
      diagnostics: {
        'status': 'UNSUPPORTED',
        'platform': 'non-android',
        'pass': false,
      },
    );
  }

  Map<String, dynamic> toMap() => {
    'phase': phase,
    'pass': pass,
    'videoOnlyBoundaryPreserved': videoOnlyBoundaryPreserved,
    'roomAudioBoundaryPreserved': roomAudioBoundaryPreserved,
    'transportAgnostic': transportAgnostic,
    'checks': checks.map((k, v) => MapEntry(k, v.toMap())),
    'raw': raw,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGRtcVideoDiagnosticsReport(phase=$phase, pass=$pass, checksCount=${checks.length})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Public Diagnostics Client
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 4C3Y: Public Dart client for Android True-DAG RTC video diagnostics.
///
/// Dispatches calls to all seven native Android RTC diagnostic MethodChannel routes:
/// 1. `runAndroidDagPhase4C3DRtcContractSmoke` (Phase 4C3D: RTC video contracts)
/// 2. `runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke` (Phase 4C3G: Realtime video adapters)
/// 3. `runAndroidDagPhase4C3KRtcMetadataSmoke` (Phase 4C3K: RTC timestamp & orientation metadata)
/// 4. `runAndroidDagPhase4C3NRtcBackpressureSmoke` (Phase 4C3N: RTC backpressure controller)
/// 5. `runAndroidDagPhase4C3QRtcFrameValidatorSmoke` (Phase 4C3Q: RTC frame validator)
/// 6. `runAndroidDagPhase4C3UProcessedVideoEgressSmoke` (Phase 4C3U: Processed video egress)
/// 7. `runAndroidDagPhase4C4BRtcJitterBufferSmoke` (Phase 4C4B: RTC jitter buffer controller)
///
/// Invariants:
/// - Video-only: Vanguard has zero room or audio ownership.
/// - Transport-agnostic: No LiveKit/WebRTC SDK coupling in Vanguard core.
/// - Defensive: Catches [MissingPluginException] and returns typed unsupported report.
class VGRtcVideoDiagnosticsClient {
  final MethodChannel _channel;

  VGRtcVideoDiagnosticsClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  /// Runs all seven Android RTC video diagnostic checks sequentially and returns an aggregated [VGRtcVideoDiagnosticsReport].
  Future<VGRtcVideoDiagnosticsReport> runAll({
    VGRtcVideoDiagnosticsRequest request = const VGRtcVideoDiagnosticsRequest(),
  }) async {
    final checks = <String, VGRtcVideoDiagnosticsCheckResult>{};
    bool allPass = true;
    final diagMap = <String, dynamic>{};

    try {
      // 1. Phase 4C3D: RTC Contract Smoke
      final contractResult = await _invokeRoute(
        'contract',
        'runAndroidDagPhase4C3DRtcContractSmoke',
        <String, dynamic>{
          'width': request.width,
          'height': request.height,
          'frameCount': request.frameCount,
        },
      );
      checks['contract'] = contractResult;
      if (!contractResult.pass) allPass = false;

      // 2. Phase 4C3G: Realtime Video Adapter Smoke
      final adapterResult = await _invokeRoute(
        'adapter',
        'runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke',
        <String, dynamic>{
          'width': request.width,
          'height': request.height,
          'frameCount': request.frameCount,
        },
      );
      checks['adapter'] = adapterResult;
      if (!adapterResult.pass) allPass = false;

      // 3. Phase 4C3K: RTC Metadata Smoke
      final metadataResult = await _invokeRoute(
        'metadata',
        'runAndroidDagPhase4C3KRtcMetadataSmoke',
        null,
      );
      checks['metadata'] = metadataResult;
      if (!metadataResult.pass) allPass = false;

      // 4. Phase 4C3N: RTC Backpressure Smoke
      final backpressureResult = await _invokeRoute(
        'backpressure',
        'runAndroidDagPhase4C3NRtcBackpressureSmoke',
        null,
      );
      checks['backpressure'] = backpressureResult;
      if (!backpressureResult.pass) allPass = false;

      // 5. Phase 4C3Q: RTC Frame Validator Smoke
      final validatorResult = await _invokeRoute(
        'validator',
        'runAndroidDagPhase4C3QRtcFrameValidatorSmoke',
        <String, dynamic>{'width': request.width, 'height': request.height},
      );
      checks['validator'] = validatorResult;
      if (!validatorResult.pass) allPass = false;

      // 6. Phase 4C3U: Processed Video Egress Smoke
      final egressResult = await _invokeRoute(
        'processedEgress',
        'runAndroidDagPhase4C3UProcessedVideoEgressSmoke',
        <String, dynamic>{
          'width': request.width,
          'height': request.height,
          'frameCount': request.frameCount,
        },
      );
      checks['processedEgress'] = egressResult;
      if (!egressResult.pass) allPass = false;

      // 7. Phase 4C4B: RTC Jitter Buffer Smoke
      final jitterResult = await _invokeRoute(
        'jitterBuffer',
        'runAndroidDagPhase4C4BRtcJitterBufferSmoke',
        <String, dynamic>{'frameCount': request.frameCount},
      );
      checks['jitterBuffer'] = jitterResult;
      if (!jitterResult.pass) allPass = false;
    } on MissingPluginException {
      return VGRtcVideoDiagnosticsReport.unsupported();
    }

    final rawStatus = allPass
        ? 'status=OK;allChecksPassed=true'
        : 'status=FAIL;failedChecks=${checks.entries.where((e) => !e.value.pass).map((e) => e.key).join(',')}';

    diagMap['pass'] = allPass;
    diagMap['videoOnlyBoundaryPreserved'] = true;
    diagMap['roomAudioBoundaryPreserved'] = true;
    diagMap['transportAgnostic'] = true;
    diagMap['routes'] = checks.map((k, v) => MapEntry(k, v.toMap()));
    for (final entry in checks.entries) {
      diagMap['${entry.key}Pass'] = entry.value.pass;
      diagMap['${entry.key}Raw'] = entry.value.raw;
    }

    return VGRtcVideoDiagnosticsReport(
      phase: 'Phase4C3Y',
      pass: allPass,
      videoOnlyBoundaryPreserved: true,
      roomAudioBoundaryPreserved: true,
      transportAgnostic: true,
      checks: checks,
      raw: rawStatus,
      diagnostics: diagMap,
    );
  }

  /// Runs individual Phase 4C3D RTC contract smoke check.
  Future<VGRtcVideoDiagnosticsCheckResult> runContractSmoke({
    int width = 64,
    int height = 64,
    int frameCount = 3,
  }) async {
    try {
      return await _invokeRoute(
        'contract',
        'runAndroidDagPhase4C3DRtcContractSmoke',
        <String, dynamic>{
          'width': width,
          'height': height,
          'frameCount': frameCount,
        },
      );
    } on MissingPluginException {
      return VGRtcVideoDiagnosticsCheckResult.unsupported('contract');
    }
  }

  /// Runs individual Phase 4C3G realtime video adapter smoke check.
  Future<VGRtcVideoDiagnosticsCheckResult> runAdapterSmoke({
    int width = 64,
    int height = 64,
    int frameCount = 3,
  }) async {
    try {
      return await _invokeRoute(
        'adapter',
        'runAndroidDagPhase4C3GRealtimeVideoAdapterSmoke',
        <String, dynamic>{
          'width': width,
          'height': height,
          'frameCount': frameCount,
        },
      );
    } on MissingPluginException {
      return VGRtcVideoDiagnosticsCheckResult.unsupported('adapter');
    }
  }

  /// Runs individual Phase 4C3K RTC metadata smoke check.
  Future<VGRtcVideoDiagnosticsCheckResult> runMetadataSmoke() async {
    try {
      return await _invokeRoute(
        'metadata',
        'runAndroidDagPhase4C3KRtcMetadataSmoke',
        null,
      );
    } on MissingPluginException {
      return VGRtcVideoDiagnosticsCheckResult.unsupported('metadata');
    }
  }

  /// Runs individual Phase 4C3N RTC backpressure smoke check.
  Future<VGRtcVideoDiagnosticsCheckResult> runBackpressureSmoke() async {
    try {
      return await _invokeRoute(
        'backpressure',
        'runAndroidDagPhase4C3NRtcBackpressureSmoke',
        null,
      );
    } on MissingPluginException {
      return VGRtcVideoDiagnosticsCheckResult.unsupported('backpressure');
    }
  }

  /// Runs individual Phase 4C3Q RTC frame validator smoke check.
  Future<VGRtcVideoDiagnosticsCheckResult> runFrameValidatorSmoke({
    int width = 64,
    int height = 64,
  }) async {
    try {
      return await _invokeRoute(
        'validator',
        'runAndroidDagPhase4C3QRtcFrameValidatorSmoke',
        <String, dynamic>{'width': width, 'height': height},
      );
    } on MissingPluginException {
      return VGRtcVideoDiagnosticsCheckResult.unsupported('validator');
    }
  }

  /// Runs individual Phase 4C3U processed video egress smoke check.
  Future<VGRtcVideoDiagnosticsCheckResult> runProcessedVideoEgressSmoke({
    int width = 64,
    int height = 64,
    int frameCount = 3,
  }) async {
    try {
      return await _invokeRoute(
        'processedEgress',
        'runAndroidDagPhase4C3UProcessedVideoEgressSmoke',
        <String, dynamic>{
          'width': width,
          'height': height,
          'frameCount': frameCount,
        },
      );
    } on MissingPluginException {
      return VGRtcVideoDiagnosticsCheckResult.unsupported('processedEgress');
    }
  }

  /// Runs individual Phase 4C4B RTC jitter buffer smoke check.
  Future<VGRtcVideoDiagnosticsCheckResult> runJitterBufferSmoke({
    int frameCount = 3,
  }) async {
    try {
      return await _invokeRoute(
        'jitterBuffer',
        'runAndroidDagPhase4C4BRtcJitterBufferSmoke',
        <String, dynamic>{'frameCount': frameCount},
      );
    } on MissingPluginException {
      return VGRtcVideoDiagnosticsCheckResult.unsupported('jitterBuffer');
    }
  }

  Future<VGRtcVideoDiagnosticsCheckResult> _invokeRoute(
    String key,
    String method,
    Map<String, dynamic>? args,
  ) async {
    try {
      final resp = await _channel.invokeMethod<Object?>(method, args);
      if (resp == null || resp is! Map) {
        return VGRtcVideoDiagnosticsCheckResult.failure(
          key,
          'invalid_response:$resp',
        );
      }
      return VGRtcVideoDiagnosticsCheckResult.fromMap(key, resp);
    } on MissingPluginException {
      rethrow;
    } catch (e) {
      return VGRtcVideoDiagnosticsCheckResult.failure(key, 'exception:$e');
    }
  }
}
