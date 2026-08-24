import 'vg_streaming_codec_capability_client.dart';
import 'vg_streaming_compatibility_decision_client.dart';
import 'vg_streaming_manifest_policy_client.dart';
import 'vg_streaming_preflight_client.dart';

/// Structured composite evaluation result combining manifest policy validation,
/// device codec capabilities, compatibility decisions, and optional preflight advisories.
class VGStreamingPreflightCompositeEvaluation {
  /// Whether overall composite streaming preflight evaluation passed.
  final bool pass;

  /// Deterministic status code describing composite evaluation outcome.
  final String status;

  /// Whether baseline AVC/H.264 decoder support is confirmed across codec and compatibility reports.
  final bool avcBaselinePass;

  /// Whether server ladder policy and segment rejection requirements are satisfied.
  final bool serverLadderPolicyPass;

  /// Server ladder policy requirement string.
  final String serverLadderPolicy;

  /// Guidance note for iOS mirror implementations.
  final String iosMirrorNote;

  /// Deduplicated diagnostic and advisory warnings encountered across all reports.
  final List<String> warnings;

  /// Map of stream entry keys to preferred codec families.
  final Map<String, String> preferredCodecs;

  /// Map of stream entry keys to fallback codec families.
  final Map<String, String> fallbackCodecs;

  /// Map of stream entry keys to evaluated stream decisions.
  final Map<String, String> streamDecisions;

  /// Total number of streams evaluated across compatibility reports.
  final int totalStreamsEvaluated;

  /// Total number of streams that passed compatibility evaluation.
  final int passedStreams;

  /// Total number of streams that failed compatibility evaluation.
  final int failedStreams;

  /// Underlying manifest policy validation report.
  final VGStreamingManifestPolicyValidationReport manifestReport;

  /// Underlying codec capability report.
  final VGStreamingCodecCapabilityReport codecReport;

  /// Underlying compatibility decision report.
  final VGStreamingCompatibilityDecisionReport compatibilityReport;

  /// Optional underlying streaming preflight advisory report.
  final VGStreamingPreflightReport? preflightReport;

  /// Diagnostic telemetry dictionary summarizing composite evaluation details.
  final Map<String, Object?> diagnostics;

  VGStreamingPreflightCompositeEvaluation({
    required this.pass,
    required this.status,
    required this.avcBaselinePass,
    required this.serverLadderPolicyPass,
    required this.serverLadderPolicy,
    required this.iosMirrorNote,
    required List<String> warnings,
    required Map<String, String> preferredCodecs,
    required Map<String, String> fallbackCodecs,
    required Map<String, String> streamDecisions,
    required this.totalStreamsEvaluated,
    required this.passedStreams,
    required this.failedStreams,
    required this.manifestReport,
    required this.codecReport,
    required this.compatibilityReport,
    this.preflightReport,
    required Map<String, Object?> diagnostics,
  }) : warnings = List<String>.unmodifiable(warnings),
       preferredCodecs = Map<String, String>.unmodifiable(preferredCodecs),
       fallbackCodecs = Map<String, String>.unmodifiable(fallbackCodecs),
       streamDecisions = Map<String, String>.unmodifiable(streamDecisions),
       diagnostics = Map<String, Object?>.unmodifiable(diagnostics);

  /// Whether playback is blocked based on preflight composite evaluation.
  bool get blocked => !pass;

  /// Confirmation invariant: pure advisory with zero player allocation.
  bool get advisoryOnly => preflightReport?.advisoryOnly ?? true;

  /// Confirmation invariant: zero playback mutation.
  bool get playbackMutation => preflightReport?.playbackMutation ?? false;

  @override
  String toString() =>
      'VGStreamingPreflightCompositeEvaluation(pass=$pass, status=$status, '
      'avcBaselinePass=$avcBaselinePass, serverLadderPolicyPass=$serverLadderPolicyPass, '
      'totalStreamsEvaluated=$totalStreamsEvaluated, passedStreams=$passedStreams, '
      'failedStreams=$failedStreams, warnings=${warnings.length})';
}

/// Pure Dart synchronous composite evaluator for streaming preflight reports.
abstract final class VGStreamingPreflightCompositeEvaluator {
  /// Evaluates manifest policy, codec capability, compatibility decision, and optional preflight reports.
  static VGStreamingPreflightCompositeEvaluation evaluate({
    required VGStreamingManifestPolicyValidationReport manifestReport,
    required VGStreamingCodecCapabilityReport codecReport,
    required VGStreamingCompatibilityDecisionReport compatibilityReport,
    VGStreamingPreflightReport? preflightReport,
  }) {
    final isUnsupported =
        manifestReport.phase == 'unsupported' ||
        codecReport.phase == 'unsupported' ||
        compatibilityReport.phase == 'unsupported' ||
        (preflightReport != null && preflightReport.phase == 'unsupported');

    final advisoryInvariantViolated =
        preflightReport != null &&
        (!preflightReport.advisoryOnly || preflightReport.playbackMutation);

    final manifestPolicyFailed =
        !manifestReport.pass || !manifestReport.segmentRejectionPass;

    final codecCapabilityFailed =
        !codecReport.pass || !codecReport.avcPass || !codecReport.avcSupported;

    final compatibilityDecisionFailed =
        !compatibilityReport.pass || compatibilityReport.failedReports > 0;

    final preflightReportFailed =
        preflightReport != null && !preflightReport.pass;

    final String status;
    if (isUnsupported) {
      status = 'unsupported_platform';
    } else if (advisoryInvariantViolated) {
      status = 'advisory_invariant_violated';
    } else if (manifestPolicyFailed) {
      status = 'manifest_policy_failed';
    } else if (codecCapabilityFailed) {
      status = 'codec_capability_failed';
    } else if (compatibilityDecisionFailed) {
      status = 'compatibility_decision_failed';
    } else if (preflightReportFailed) {
      status = 'preflight_report_failed';
    } else {
      status = 'evaluation_passed';
    }

    final pass = status == 'evaluation_passed';

    final avcBaselinePass =
        codecReport.avcPass &&
        codecReport.avcSupported &&
        compatibilityReport.avcSupported;

    final serverLadderPolicyPass =
        manifestReport.pass &&
        manifestReport.segmentRejectionPass &&
        codecReport.fallbackPolicyPass;

    final serverLadderPolicy = _resolveFirstNonEmpty([
      preflightReport?.serverLadderPolicy,
      compatibilityReport.serverLadderPolicy,
      codecReport.serverLadderPolicy,
      manifestReport.serverLadderPolicy,
    ]);

    final iosMirrorNote = _resolveFirstNonEmpty([
      preflightReport?.iosMirrorNote,
      compatibilityReport.iosMirrorNote,
      codecReport.iosMirrorNote,
      manifestReport.iosMirrorNote,
    ]);

    final rawWarnings = <String>[];
    if (isUnsupported) {
      rawWarnings.add('unsupported_platform');
    }
    if (advisoryInvariantViolated) {
      rawWarnings.add('advisory_invariant_violated');
    }
    rawWarnings.addAll(compatibilityReport.deviceWarnings);
    for (final entry in compatibilityReport.reports) {
      rawWarnings.addAll(entry.warnings);
    }
    if (preflightReport != null) {
      rawWarnings.addAll(preflightReport.warnings);
      rawWarnings.addAll(preflightReport.deviceWarnings);
    }
    if (status != 'evaluation_passed' && !rawWarnings.contains(status)) {
      rawWarnings.add(status);
    }

    // Deduplicate in encounter order
    final seenWarnings = <String>{};
    final warnings = <String>[];
    for (final w in rawWarnings) {
      if (seenWarnings.add(w)) {
        warnings.add(w);
      }
    }

    final preferredCodecs = <String, String>{};
    final fallbackCodecs = <String, String>{};
    final streamDecisions = <String, String>{};

    for (final entry in compatibilityReport.reports) {
      preferredCodecs[entry.key] = entry.preferredCodecFamily;
      fallbackCodecs[entry.key] = entry.fallbackCodecFamily;
      streamDecisions[entry.key] = entry.decision;
    }

    final totalStreamsEvaluated = compatibilityReport.totalReports;
    final passedStreams = compatibilityReport.passedReports;
    final failedStreams = compatibilityReport.failedReports;

    final diagnostics = <String, Object?>{
      'status': status,
      'pass': pass,
      'manifestPass': manifestReport.pass,
      'segmentRejectionPass': manifestReport.segmentRejectionPass,
      'codecPass': codecReport.pass,
      'avcBaselinePass': avcBaselinePass,
      'compatibilityPass': compatibilityReport.pass,
      'preflightPass': preflightReport?.pass,
      'serverLadderPolicyPass': serverLadderPolicyPass,
      'totalStreamsEvaluated': totalStreamsEvaluated,
      'passedStreams': passedStreams,
      'failedStreams': failedStreams,
      'warningCount': warnings.length,
      'preferredCodecCount': preferredCodecs.length,
      'fallbackCodecCount': fallbackCodecs.length,
      'streamDecisionCount': streamDecisions.length,
    };

    return VGStreamingPreflightCompositeEvaluation(
      pass: pass,
      status: status,
      avcBaselinePass: avcBaselinePass,
      serverLadderPolicyPass: serverLadderPolicyPass,
      serverLadderPolicy: serverLadderPolicy,
      iosMirrorNote: iosMirrorNote,
      warnings: warnings,
      preferredCodecs: preferredCodecs,
      fallbackCodecs: fallbackCodecs,
      streamDecisions: streamDecisions,
      totalStreamsEvaluated: totalStreamsEvaluated,
      passedStreams: passedStreams,
      failedStreams: failedStreams,
      manifestReport: manifestReport,
      codecReport: codecReport,
      compatibilityReport: compatibilityReport,
      preflightReport: preflightReport,
      diagnostics: diagnostics,
    );
  }

  static String _resolveFirstNonEmpty(List<String?> candidates) {
    for (final candidate in candidates) {
      if (candidate != null && candidate.isNotEmpty) {
        return candidate;
      }
    }
    return '';
  }
}
