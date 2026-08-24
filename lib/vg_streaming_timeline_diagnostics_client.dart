// Copyright (c) Connects — Vanguard Phase 4C4J.
// Public package-level adaptive stream timeline diagnostics API client for Android True-DAG backend.
//
// Invariants:
// - Diagnostic Only: Wraps native MethodChannel adaptive stream timeline diagnostic route.
//   Proves timeline monotonicity, duplicate dropping, out-of-order rejection, late dropping,
//   future retryability, seek rebasing, rendition rebasing, and live-offset policy without
//   controlling playback ABR or mutating product feed policies.
// - Safe on Non-Android: Catches MissingPluginException and returns typed unsupported
//   report without crashing.
// - Transport Agnostic: No direct dependency on network I/O or concrete streaming formats.

import 'dart:async';

import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Request Models
// ─────────────────────────────────────────────────────────────────────────────

/// Request configuration for [VGStreamingTimelineDiagnosticsClient.run].
class VGStreamingTimelineDiagnosticsRequest {
  /// Number of sequential on-time frames to evaluate in the initial pass (must be positive).
  final int frameCount;

  const VGStreamingTimelineDiagnosticsRequest({this.frameCount = 5})
    : assert(frameCount > 0, 'frameCount must be positive');

  Map<String, dynamic> toMap() => {'frameCount': frameCount};

  @override
  String toString() =>
      'VGStreamingTimelineDiagnosticsRequest(frameCount=$frameCount)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Report Models
// ─────────────────────────────────────────────────────────────────────────────

/// Diagnostic report verifying all 11 adaptive stream timeline invariants.
class VGStreamingTimelineDiagnosticsReport {
  /// Diagnostic phase identifier (e.g. 'Phase4C4J' or 'unsupported').
  final String phase;

  /// Overall pass status across all 11 stream timeline invariants.
  final bool pass;

  /// Number of sequential frames evaluated in the pass.
  final int frameCount;

  /// Invariant 1: Sequential on-time frames accepted and timeline advanced.
  final bool sequentialPass;

  /// Invariant 2: Duplicate frame with identical index/PTS dropped.
  final bool duplicatePass;

  /// Invariant 3: Out-of-order older frame dropped.
  final bool outOfOrderPass;

  /// Invariant 4: Late frame exceeding late threshold dropped.
  final bool latePass;

  /// Invariant 5: Future frame exceeding max lead rejected with retryable status.
  final bool futurePass;

  /// Invariant 6: Rejected future frame accepted on subsequent on-time arrival.
  final bool futureRetryPass;

  /// Invariant 7: Seek rebase increments generationId and re-anchors timeline.
  final bool seekRebasePass;

  /// Invariant 8: Rendition-step rebase increments generationId and re-anchors timeline.
  final bool renditionRebasePass;

  /// Invariant 9: Live offset speed policy recommends SPEED_UP, SLOW_DOWN, HOLD, REBUFFER_MARGIN.
  final bool liveOffsetPolicyPass;

  /// Invariant 10: Invalid negative inputs fail gracefully with non-retryable status.
  final bool negativeInputPass;

  /// Invariant 11: Reset clears counters and returns timeline to unstarted state.
  final bool resetPass;

  /// Raw diagnostic summary string from native.
  final String raw;

  /// Complete details and telemetry map returned by native.
  final Map<String, dynamic> diagnostics;

  const VGStreamingTimelineDiagnosticsReport({
    this.phase = 'Phase4C4J',
    required this.pass,
    this.frameCount = 5,
    this.sequentialPass = false,
    this.duplicatePass = false,
    this.outOfOrderPass = false,
    this.latePass = false,
    this.futurePass = false,
    this.futureRetryPass = false,
    this.seekRebasePass = false,
    this.renditionRebasePass = false,
    this.liveOffsetPolicyPass = false,
    this.negativeInputPass = false,
    this.resetPass = false,
    required this.raw,
    required this.diagnostics,
  });

  factory VGStreamingTimelineDiagnosticsReport.fromMap(
    Map<dynamic, dynamic>? map, {
    int requestedFrameCount = 5,
  }) {
    if (map == null) {
      return VGStreamingTimelineDiagnosticsReport.failure('null_response');
    }
    final details = Map<String, dynamic>.from(map);
    final sequentialPass = details['sequentialPass'] == true;
    final duplicatePass = details['duplicatePass'] == true;
    final outOfOrderPass = details['outOfOrderPass'] == true;
    final latePass = details['latePass'] == true;
    final futurePass = details['futurePass'] == true;
    final futureRetryPass = details['futureRetryPass'] == true;
    final seekRebasePass = details['seekRebasePass'] == true;
    final renditionRebasePass = details['renditionRebasePass'] == true;
    final liveOffsetPolicyPass = details['liveOffsetPolicyPass'] == true;
    final negativeInputPass = details['negativeInputPass'] == true;
    final resetPass = details['resetPass'] == true;

    final allInvariantsPass =
        sequentialPass &&
        duplicatePass &&
        outOfOrderPass &&
        latePass &&
        futurePass &&
        futureRetryPass &&
        seekRebasePass &&
        renditionRebasePass &&
        liveOffsetPolicyPass &&
        negativeInputPass &&
        resetPass;

    final overallPass = (details['pass'] == true) && allInvariantsPass;
    final effectiveFrameCount =
        (details['frameCount'] as num?)?.toInt() ?? requestedFrameCount;
    final raw =
        details['raw']?.toString() ??
        (overallPass ? 'status=OK' : 'status=FAIL');

    return VGStreamingTimelineDiagnosticsReport(
      phase: 'Phase4C4J',
      pass: overallPass,
      frameCount: effectiveFrameCount,
      sequentialPass: sequentialPass,
      duplicatePass: duplicatePass,
      outOfOrderPass: outOfOrderPass,
      latePass: latePass,
      futurePass: futurePass,
      futureRetryPass: futureRetryPass,
      seekRebasePass: seekRebasePass,
      renditionRebasePass: renditionRebasePass,
      liveOffsetPolicyPass: liveOffsetPolicyPass,
      negativeInputPass: negativeInputPass,
      resetPass: resetPass,
      raw: raw,
      diagnostics: details,
    );
  }

  factory VGStreamingTimelineDiagnosticsReport.failure(
    String reason, [
    Map<String, dynamic>? details,
  ]) {
    return VGStreamingTimelineDiagnosticsReport(
      phase: 'Phase4C4J',
      pass: false,
      frameCount: 0,
      sequentialPass: false,
      duplicatePass: false,
      outOfOrderPass: false,
      latePass: false,
      futurePass: false,
      futureRetryPass: false,
      seekRebasePass: false,
      renditionRebasePass: false,
      liveOffsetPolicyPass: false,
      negativeInputPass: false,
      resetPass: false,
      raw: 'status=FAIL;reason=$reason',
      diagnostics: details ?? {'pass': false, 'error': reason},
    );
  }

  factory VGStreamingTimelineDiagnosticsReport.unsupported() {
    return const VGStreamingTimelineDiagnosticsReport(
      phase: 'unsupported',
      pass: false,
      frameCount: 0,
      sequentialPass: false,
      duplicatePass: false,
      outOfOrderPass: false,
      latePass: false,
      futurePass: false,
      futureRetryPass: false,
      seekRebasePass: false,
      renditionRebasePass: false,
      liveOffsetPolicyPass: false,
      negativeInputPass: false,
      resetPass: false,
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
    'frameCount': frameCount,
    'sequentialPass': sequentialPass,
    'duplicatePass': duplicatePass,
    'outOfOrderPass': outOfOrderPass,
    'latePass': latePass,
    'futurePass': futurePass,
    'futureRetryPass': futureRetryPass,
    'seekRebasePass': seekRebasePass,
    'renditionRebasePass': renditionRebasePass,
    'liveOffsetPolicyPass': liveOffsetPolicyPass,
    'negativeInputPass': negativeInputPass,
    'resetPass': resetPass,
    'raw': raw,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingTimelineDiagnosticsReport(phase=$phase, pass=$pass, frameCount=$frameCount, raw=$raw)';
}

// ─────────────────────────────────────────────────────────────────────────────
// Public Diagnostics Client
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 4C4J: Public Dart client for Android True-DAG adaptive stream timeline diagnostics.
///
/// Dispatches calls to native Android diagnostic MethodChannel route:
/// - `runAndroidDagPhase4C4GAdaptiveStreamTimelineSmoke` (Phase 4C4G: Adaptive stream timeline controller smoke)
///
/// Invariants:
/// - Metadata-only timeline verification: validates PTS monotonicity, duplicate/late/out-of-order rejection,
///   future frame retryability, seek/rendition rebasing, and live offset speed policy without buffer retention.
/// - Diagnostic-only: wraps diagnostic harness, does not alter native player ABR or feed policies.
/// - Defensive: Catches [MissingPluginException] and returns typed unsupported report on non-Android platforms.
class VGStreamingTimelineDiagnosticsClient {
  final MethodChannel _channel;

  VGStreamingTimelineDiagnosticsClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('vanguard_media_engine');

  /// Runs the adaptive stream timeline diagnostic verification suite and returns a [VGStreamingTimelineDiagnosticsReport].
  Future<VGStreamingTimelineDiagnosticsReport> run({
    VGStreamingTimelineDiagnosticsRequest request =
        const VGStreamingTimelineDiagnosticsRequest(),
  }) async {
    try {
      final resp = await _channel.invokeMethod<Object?>(
        'runAndroidDagPhase4C4GAdaptiveStreamTimelineSmoke',
        request.toMap(),
      );
      if (resp == null || resp is! Map) {
        return VGStreamingTimelineDiagnosticsReport.failure(
          'invalid_response:$resp',
        );
      }
      return VGStreamingTimelineDiagnosticsReport.fromMap(
        resp,
        requestedFrameCount: request.frameCount,
      );
    } on MissingPluginException {
      return VGStreamingTimelineDiagnosticsReport.unsupported();
    } catch (e) {
      return VGStreamingTimelineDiagnosticsReport.failure('exception:$e');
    }
  }
}
