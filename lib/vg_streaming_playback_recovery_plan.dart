// Copyright (c) Connects — Vanguard Phase 4C7AK.
// Public streaming playback recovery planner.
//
// Pure Dart advisory helper: converts VGStreamingPlaybackHealthAdvice, current playback
// status summary, and active playback options into a typed, immutable recovery plan
// without mutating playback, reopening sessions, forcing ABR, or calling platform channels.
//
// Bounded convenience wrapper: does NOT execute open/play/pause/stop/dispose, does NOT
// allocate native decoders/surfaces, and does NOT control product feed policies.

import 'vg_streaming_playback_client.dart';
import 'vg_streaming_playback_health_advisor.dart';

export 'vg_streaming_playback_client.dart'
    show
        VGStreamingFormatHint,
        VGStreamingNetworkProfile,
        VGStreamingPlaybackOptions;
export 'vg_streaming_playback_health_advisor.dart'
    show
        VGStreamingPlaybackHealthAction,
        VGStreamingPlaybackHealthAdvice,
        VGStreamingPlaybackHealthAdvisor,
        VGStreamingPlaybackHealthSeverity;
export 'vg_streaming_playback_status_summary.dart'
    show VGStreamingPlaybackStatusSummary;

/// High-level recovery intent recommended for the host application or player manager.
enum VGStreamingPlaybackRecoveryIntent {
  /// No recovery action needed; session is healthy or optimal.
  none,

  /// Wait passively for the playback look-ahead buffer or network readahead to recover.
  waitForBuffer,

  /// Retry or reopen playback using current or recommended network profile.
  retryCurrentProfile,

  /// Reopen or switch playback to a constrained network profile for bandwidth relief.
  retryConstrainedProfile,

  /// Step back from low-latency mode to standard latency and constrained profile.
  reopenStandardLatency,

  /// Playback reached an unrecoverable terminal state; do not attempt automated recovery.
  stopTerminal;

  /// Serializes intent to lowercase camelCase string.
  String toJson() => name;
}

/// Urgency level of the recommended recovery plan.
enum VGStreamingPlaybackRecoveryUrgency {
  /// No recovery urgency (healthy playback or completed/unrecoverable stream).
  none,

  /// Passive adjustment (e.g. waiting for buffer, opportunistic stable profile suggestion).
  passive,

  /// Proactive profile switch or retry to resolve degraded or repeated rebuffering.
  active,

  /// Immediate action required (e.g. stalled playhead, recoverable failure, leaving low-latency).
  immediate;

  /// Serializes urgency to lowercase string.
  String toJson() => name;
}

/// Immutable request configuration for streaming playback recovery planning.
class VGStreamingPlaybackRecoveryPlanRequest {
  /// Health advice produced by [VGStreamingPlaybackHealthAdvisor].
  final VGStreamingPlaybackHealthAdvice advice;

  /// Optional current playback status summary.
  final VGStreamingPlaybackStatusSummary? currentStatus;

  /// Optional active playback options used to configure the current session.
  final VGStreamingPlaybackOptions? currentOptions;

  /// Whether the host application policy permits automated retry without manual user intervention.
  final bool allowAutomaticRetry;

  /// Recommended cooldown / backoff delay in milliseconds before dispatching recovery action.
  final int retryDelayMs;

  /// Optional explicit resume position override in milliseconds (clamped to >= 0).
  final int? resumePositionOverrideMs;

  /// Whether cache configuration from [currentOptions] should be preserved in cloned recovery options.
  final bool preserveCacheOptions;

  const VGStreamingPlaybackRecoveryPlanRequest({
    required this.advice,
    this.currentStatus,
    this.currentOptions,
    this.allowAutomaticRetry = false,
    this.retryDelayMs = 750,
    this.resumePositionOverrideMs,
    this.preserveCacheOptions = true,
  }) : assert(retryDelayMs >= 0, 'retryDelayMs must be >= 0'),
       assert(
         resumePositionOverrideMs == null || resumePositionOverrideMs >= 0,
         'resumePositionOverrideMs must be >= 0',
       );

  /// Serializes request to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'advice': advice.toJson(),
    if (currentStatus != null) 'currentStatus': currentStatus!.toJson(),
    if (currentOptions != null) 'currentOptions': currentOptions!.toArgs(),
    'allowAutomaticRetry': allowAutomaticRetry,
    'retryDelayMs': retryDelayMs,
    if (resumePositionOverrideMs != null)
      'resumePositionOverrideMs': resumePositionOverrideMs,
    'preserveCacheOptions': preserveCacheOptions,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackRecoveryPlanRequest(advice=$advice, '
      'allowAutomaticRetry=$allowAutomaticRetry, retryDelayMs=$retryDelayMs, '
      'hasCurrentOptions=${currentOptions != null}, hasCurrentStatus=${currentStatus != null})';
}

/// Immutable result of a streaming playback recovery plan evaluation.
class VGStreamingPlaybackRecoveryPlan {
  /// Recommended recovery intent for the host application.
  final VGStreamingPlaybackRecoveryIntent intent;

  /// Urgency level of the recovery action.
  final VGStreamingPlaybackRecoveryUrgency urgency;

  /// Whether the session requires re-opening playback to apply recovery adjustments.
  final bool shouldReopenPlayback;

  /// Whether host application intervention is strictly required to execute recovery.
  final bool requiresHostAction;

  /// Whether validated [playbackOptions] were successfully synthesized from [currentOptions].
  final bool canBuildPlaybackOptions;

  /// Cloned and adjusted playback options ready for [VGStreamingPlaybackClient.open], or `null`.
  final VGStreamingPlaybackOptions? playbackOptions;

  /// Recommended resume position in milliseconds for reopening playback (clamped to >= 0, or `null`).
  final int? resumePositionMs;

  /// Cooldown / backoff delay in milliseconds before attempting recovery.
  final int retryDelayMs;

  /// Invariant: always `true` (pure advisory; zero native/player allocations).
  final bool advisoryOnly;

  /// Invariant: always `false` (zero playback mutation).
  final bool playbackMutation;

  /// Immutable list of rationale and warning codes that justified this recovery plan.
  final List<String> reasons;

  /// Diagnostics dictionary containing evaluated telemetry metrics.
  final Map<String, Object?> diagnostics;

  /// Convenience alias for [reasons].
  List<String> get warnings => reasons;

  const VGStreamingPlaybackRecoveryPlan({
    required this.intent,
    required this.urgency,
    required this.shouldReopenPlayback,
    required this.requiresHostAction,
    required this.canBuildPlaybackOptions,
    this.playbackOptions,
    this.resumePositionMs,
    required this.retryDelayMs,
    this.advisoryOnly = true,
    this.playbackMutation = false,
    this.reasons = const <String>[],
    this.diagnostics = const <String, Object?>{},
  });

  /// Serializes recovery plan to map.
  Map<String, Object?> toJson() => <String, Object?>{
    'intent': intent.name,
    'urgency': urgency.name,
    'shouldReopenPlayback': shouldReopenPlayback,
    'requiresHostAction': requiresHostAction,
    'canBuildPlaybackOptions': canBuildPlaybackOptions,
    if (playbackOptions != null) 'playbackOptions': playbackOptions!.toArgs(),
    if (resumePositionMs != null) 'resumePositionMs': resumePositionMs,
    'retryDelayMs': retryDelayMs,
    'advisoryOnly': advisoryOnly,
    'playbackMutation': playbackMutation,
    'reasons': reasons,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackRecoveryPlan(intent=$intent, urgency=$urgency, '
      'shouldReopenPlayback=$shouldReopenPlayback, requiresHostAction=$requiresHostAction, '
      'canBuildPlaybackOptions=$canBuildPlaybackOptions, resumePositionMs=$resumePositionMs, '
      'retryDelayMs=$retryDelayMs, reasons=$reasons)';
}

/// Pure Dart advisory helper for evaluating streaming playback recovery plans.
abstract final class VGStreamingPlaybackRecoveryPlanner {
  /// Evaluates [request] and produces an immutable [VGStreamingPlaybackRecoveryPlan].
  static VGStreamingPlaybackRecoveryPlan plan(
    VGStreamingPlaybackRecoveryPlanRequest request,
  ) {
    final advice = request.advice;
    final currentStatus = request.currentStatus;
    final currentOptions = request.currentOptions;
    final allowAutoRetry = request.allowAutomaticRetry;
    final retryDelayMs = request.retryDelayMs;
    final preserveCache = request.preserveCacheOptions;

    final reasons = <String>[];
    for (final reason in advice.reasons) {
      if (!reasons.contains(reason)) {
        reasons.add(reason);
      }
    }

    // Determine target candidate resume position:
    // - Explicit non-negative override takes precedence.
    // - For VOD streams (isLive == false), preserve current playback position.
    // - For Live streams, keep position null to track live edge unless explicit override is provided.
    final int? candidateResumePos;
    if (request.resumePositionOverrideMs != null &&
        request.resumePositionOverrideMs! >= 0) {
      candidateResumePos = request.resumePositionOverrideMs;
    } else if (currentStatus != null &&
        !currentStatus.isLive &&
        currentStatus.positionMs >= 0) {
      candidateResumePos = currentStatus.positionMs;
    } else {
      candidateResumePos = null;
    }

    final VGStreamingPlaybackRecoveryIntent intent;
    final VGStreamingPlaybackRecoveryUrgency urgency;
    final bool shouldReopenPlayback;
    final bool requiresHostAction;
    final bool canBuildPlaybackOptions;
    final VGStreamingPlaybackOptions? playbackOptions;
    final int? resumePositionMs;

    switch (advice.recommendedAction) {
      case VGStreamingPlaybackHealthAction.keepCurrentProfile:
        intent = VGStreamingPlaybackRecoveryIntent.none;
        urgency = VGStreamingPlaybackRecoveryUrgency.none;
        shouldReopenPlayback = false;
        requiresHostAction = false;
        canBuildPlaybackOptions = false;
        playbackOptions = null;
        resumePositionMs = null;
        if (!reasons.contains('keep_current_profile_optimal')) {
          reasons.add('keep_current_profile_optimal');
        }

      case VGStreamingPlaybackHealthAction.preferStableProfile:
        shouldReopenPlayback = false;
        urgency = VGStreamingPlaybackRecoveryUrgency.passive;
        requiresHostAction = false;

        if (currentOptions != null) {
          canBuildPlaybackOptions = true;
          playbackOptions = _cloneOptions(
            currentOptions,
            networkProfile: VGStreamingNetworkProfile.stable,
            initialPositionMs: candidateResumePos,
            preserveCacheOptions: preserveCache,
          );
          if (allowAutoRetry) {
            intent = VGStreamingPlaybackRecoveryIntent.retryCurrentProfile;
            resumePositionMs = candidateResumePos;
          } else {
            intent = VGStreamingPlaybackRecoveryIntent.none;
            resumePositionMs = null;
          }
          if (!reasons.contains('prefer_stable_profile_available')) {
            reasons.add('prefer_stable_profile_available');
          }
        } else {
          canBuildPlaybackOptions = false;
          playbackOptions = null;
          intent = VGStreamingPlaybackRecoveryIntent.none;
          resumePositionMs = null;
          if (!reasons.contains('prefer_stable_profile_no_options')) {
            reasons.add('prefer_stable_profile_no_options');
          }
        }

      case VGStreamingPlaybackHealthAction.waitForBuffer:
        intent = VGStreamingPlaybackRecoveryIntent.waitForBuffer;
        urgency = VGStreamingPlaybackRecoveryUrgency.passive;
        shouldReopenPlayback = false;
        requiresHostAction = false;
        canBuildPlaybackOptions = false;
        playbackOptions = null;
        resumePositionMs = null;
        if (!reasons.contains('wait_for_buffer_recovery')) {
          reasons.add('wait_for_buffer_recovery');
        }

      case VGStreamingPlaybackHealthAction.preferConstrainedProfile:
        intent = VGStreamingPlaybackRecoveryIntent.retryConstrainedProfile;
        urgency = VGStreamingPlaybackRecoveryUrgency.active;
        shouldReopenPlayback = true;

        if (currentOptions != null) {
          canBuildPlaybackOptions = true;
          resumePositionMs = candidateResumePos;
          playbackOptions = _cloneOptions(
            currentOptions,
            networkProfile: VGStreamingNetworkProfile.constrained,
            initialPositionMs: resumePositionMs,
            preserveCacheOptions: preserveCache,
          );
          requiresHostAction = !allowAutoRetry;
          if (!reasons.contains('prefer_constrained_profile_planned')) {
            reasons.add('prefer_constrained_profile_planned');
          }
        } else {
          canBuildPlaybackOptions = false;
          playbackOptions = null;
          resumePositionMs = null;
          requiresHostAction = true;
          if (!reasons.contains('prefer_constrained_profile_no_options')) {
            reasons.add('prefer_constrained_profile_no_options');
          }
        }

      case VGStreamingPlaybackHealthAction.leaveLowLatency:
        intent = VGStreamingPlaybackRecoveryIntent.reopenStandardLatency;
        urgency = VGStreamingPlaybackRecoveryUrgency.immediate;
        shouldReopenPlayback = true;
        requiresHostAction = true;
        resumePositionMs = candidateResumePos;

        if (currentOptions != null) {
          canBuildPlaybackOptions = true;
          playbackOptions = _cloneOptions(
            currentOptions,
            networkProfile: VGStreamingNetworkProfile.constrained,
            initialPositionMs: resumePositionMs,
            preserveCacheOptions: preserveCache,
          );
          if (!reasons.contains('leave_low_latency_reopen_constrained')) {
            reasons.add('leave_low_latency_reopen_constrained');
          }
        } else {
          canBuildPlaybackOptions = false;
          playbackOptions = null;
          if (!reasons.contains('leave_low_latency_no_options')) {
            reasons.add('leave_low_latency_no_options');
          }
        }

      case VGStreamingPlaybackHealthAction.retryPlayback:
        intent = VGStreamingPlaybackRecoveryIntent.retryCurrentProfile;
        urgency =
            (advice.severity == VGStreamingPlaybackHealthSeverity.stalled ||
                advice.severity == VGStreamingPlaybackHealthSeverity.terminal)
            ? VGStreamingPlaybackRecoveryUrgency.immediate
            : VGStreamingPlaybackRecoveryUrgency.active;
        shouldReopenPlayback = true;
        resumePositionMs = candidateResumePos;

        if (currentOptions != null) {
          canBuildPlaybackOptions = true;
          playbackOptions = _cloneOptions(
            currentOptions,
            networkProfile: advice.recommendedNetworkProfile,
            initialPositionMs: resumePositionMs,
            preserveCacheOptions: preserveCache,
          );
          requiresHostAction = !allowAutoRetry;
          if (!reasons.contains('retry_playback_reopen_planned')) {
            reasons.add('retry_playback_reopen_planned');
          }
        } else {
          canBuildPlaybackOptions = false;
          playbackOptions = null;
          requiresHostAction = true;
          if (!reasons.contains('retry_playback_no_options')) {
            reasons.add('retry_playback_no_options');
          }
        }

      case VGStreamingPlaybackHealthAction.doNotRetryTerminal:
        intent = VGStreamingPlaybackRecoveryIntent.stopTerminal;
        urgency = VGStreamingPlaybackRecoveryUrgency.none;
        shouldReopenPlayback = false;
        requiresHostAction = false;
        canBuildPlaybackOptions = false;
        playbackOptions = null;
        resumePositionMs = null;
        if (!reasons.contains('terminal_do_not_retry')) {
          reasons.add('terminal_do_not_retry');
        }
    }

    final diagnostics = <String, Object?>{
      'intent': intent.name,
      'urgency': urgency.name,
      'shouldReopenPlayback': shouldReopenPlayback,
      'requiresHostAction': requiresHostAction,
      'canBuildPlaybackOptions': canBuildPlaybackOptions,
      'hasCurrentOptions': currentOptions != null,
      'hasCurrentStatus': currentStatus != null,
      if (currentStatus != null) 'isLive': currentStatus.isLive,
      'resumePositionMs': resumePositionMs,
      'retryDelayMs': retryDelayMs,
      'allowAutomaticRetry': allowAutoRetry,
      'preserveCacheOptions': preserveCache,
      'adviceSeverity': advice.severity.name,
      'adviceAction': advice.recommendedAction.name,
      'adviceNetworkProfile': advice.recommendedNetworkProfile.toNative(),
      'advisoryOnly': true,
      'playbackMutation': false,
    };

    return VGStreamingPlaybackRecoveryPlan(
      intent: intent,
      urgency: urgency,
      shouldReopenPlayback: shouldReopenPlayback,
      requiresHostAction: requiresHostAction,
      canBuildPlaybackOptions: canBuildPlaybackOptions,
      playbackOptions: playbackOptions,
      resumePositionMs: resumePositionMs,
      retryDelayMs: retryDelayMs,
      advisoryOnly: true,
      playbackMutation: false,
      reasons: List<String>.unmodifiable(reasons),
      diagnostics: Map<String, Object?>.unmodifiable(diagnostics),
    );
  }

  /// Private helper for defensive cloning of [VGStreamingPlaybackOptions].
  static VGStreamingPlaybackOptions _cloneOptions(
    VGStreamingPlaybackOptions options, {
    VGStreamingNetworkProfile? networkProfile,
    int? initialPositionMs,
    bool preserveCacheOptions = true,
  }) {
    return VGStreamingPlaybackOptions(
      uri: options.uri,
      initialWidth: options.initialWidth,
      initialHeight: options.initialHeight,
      httpHeaders: options.httpHeaders != null
          ? Map<String, String>.unmodifiable(options.httpHeaders!)
          : null,
      formatHint: options.formatHint,
      networkProfile: networkProfile ?? options.networkProfile,
      autoPlay: options.autoPlay,
      initialPositionMs: initialPositionMs,
      cacheOptions: preserveCacheOptions ? options.cacheOptions : null,
    );
  }
}
