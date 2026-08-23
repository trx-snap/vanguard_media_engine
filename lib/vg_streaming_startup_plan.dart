// Copyright (c) Connects — Vanguard Phase 4C7G.
// Public streaming startup plan helper.
//
// Pure Dart helper: converts streaming preflight advisory reports into
// validated playback options without platform coupling or side effects.

import 'vg_streaming_cache_client.dart';
import 'vg_streaming_playback_client.dart';
import 'vg_streaming_preflight_client.dart';

export 'vg_streaming_cache_client.dart' show VGPlaybackCacheOptions;
export 'vg_streaming_playback_client.dart'
    show
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingPlaybackOptions;
export 'vg_streaming_preflight_client.dart' show VGStreamingPreflightReport;

/// Immutable startup plan derived from a [VGStreamingPreflightReport].
///
/// Ensures callers only proceed to playback when preflight validations pass
/// and invariant checks (advisory-only, zero playback mutation) are satisfied.
class VGStreamingStartupPlan {
  /// Whether streaming playback should proceed based on preflight evaluation.
  final bool shouldProceed;

  /// High-level reason or decision explanation for [shouldProceed].
  final String reason;

  /// Network profile recommended by the preflight engine.
  ///
  /// Falls back to [VGStreamingNetworkProfile.constrained] if [shouldProceed] is `false`.
  final VGStreamingNetworkProfile recommendedNetworkProfile;

  /// Combined list of advisory warnings and device-level codec warnings.
  final List<String> warnings;

  /// Original preflight advisory report from which this plan was synthesized.
  final VGStreamingPreflightReport preflightReport;

  const VGStreamingStartupPlan({
    required this.shouldProceed,
    required this.reason,
    required this.recommendedNetworkProfile,
    required this.warnings,
    required this.preflightReport,
  });

  /// Evaluates a [VGStreamingPreflightReport] and synthesizes a [VGStreamingStartupPlan].
  factory VGStreamingStartupPlan.fromPreflight(
    VGStreamingPreflightReport report,
  ) {
    final shouldProceed =
        report.pass == true &&
        report.advisoryOnly == true &&
        report.playbackMutation == false;

    final recommendedNetworkProfile = shouldProceed
        ? VGStreamingNetworkProfile.fromString(report.recommendedNetworkProfile)
        : VGStreamingNetworkProfile.constrained;

    final combinedWarnings = <String>[
      ...report.warnings,
      ...report.deviceWarnings,
    ];

    final String reason;
    if (shouldProceed) {
      reason = report.advisoryDecision.isNotEmpty
          ? report.advisoryDecision
          : 'preflight_passed';
    } else {
      final isUnsupported =
          report.phase == 'unsupported' ||
          report.advisoryDecision == 'unsupported';
      final failureMarker = isUnsupported ? 'unsupported' : 'preflight_failed';
      if (!combinedWarnings.contains(failureMarker)) {
        combinedWarnings.add(failureMarker);
      }

      if (isUnsupported) {
        reason = report.advisoryDecision.isNotEmpty
            ? report.advisoryDecision
            : 'unsupported';
      } else if (!report.pass) {
        reason = report.advisoryDecision.isNotEmpty
            ? report.advisoryDecision
            : 'preflight_failed';
      } else if (!report.advisoryOnly) {
        reason = 'advisory_only_violation';
      } else if (report.playbackMutation) {
        reason = 'playback_mutation_detected';
      } else {
        reason = 'preflight_failed';
      }
    }

    return VGStreamingStartupPlan(
      shouldProceed: shouldProceed,
      reason: reason,
      recommendedNetworkProfile: recommendedNetworkProfile,
      warnings: List<String>.unmodifiable(combinedWarnings),
      preflightReport: report,
    );
  }

  /// Builds a [VGStreamingPlaybackOptions] descriptor with caller-supplied media
  /// parameters and the [recommendedNetworkProfile] from this plan.
  ///
  /// Throws a [StateError] if [shouldProceed] is `false` to prevent accidental
  /// playback initiation from failed or unsupported preflight advisories.
  VGStreamingPlaybackOptions buildPlaybackOptions({
    required Uri uri,
    required int initialWidth,
    required int initialHeight,
    Map<String, String>? httpHeaders,
    VGStreamingFormatHint formatHint = VGStreamingFormatHint.auto,
    bool autoPlay = true,
    int? initialPositionMs,
    VGPlaybackCacheOptions? cacheOptions,
  }) {
    if (!shouldProceed) {
      throw StateError(
        'Cannot build playback options from a startup plan where shouldProceed is false (reason: $reason).',
      );
    }

    return VGStreamingPlaybackOptions(
      uri: uri,
      initialWidth: initialWidth,
      initialHeight: initialHeight,
      httpHeaders: httpHeaders,
      formatHint: formatHint,
      networkProfile: recommendedNetworkProfile,
      autoPlay: autoPlay,
      initialPositionMs: initialPositionMs,
      cacheOptions: cacheOptions,
    );
  }

  @override
  String toString() =>
      'VGStreamingStartupPlan(shouldProceed=$shouldProceed, reason=$reason, '
      'profile=$recommendedNetworkProfile, warnings=$warnings)';
}

/// Factory utility for generating [VGStreamingStartupPlan] instances.
abstract final class VGStreamingStartupPlanner {
  /// Evaluates [report] and returns a [VGStreamingStartupPlan].
  static VGStreamingStartupPlan fromPreflight(
    VGStreamingPreflightReport report,
  ) {
    return VGStreamingStartupPlan.fromPreflight(report);
  }
}
