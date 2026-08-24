// Copyright (c) Connects — Vanguard Phase 4C7AI.
// Public streaming playback health advisor.
//
// Pure Dart advisory helper: evaluates playback status summaries, buffer metrics,
// recent playback history, and optional preflight reports to recommend safe network
// profiles, buffering pauses, or retry actions for poor/choppy mobile networks.
//
// Bounded convenience wrapper: does NOT mutate playback, reopen streams, force ABR,
// change tracks directly, touch cache, or handle product feed policy.

import 'vg_streaming_playback_status_summary.dart';
import 'vg_streaming_preflight_client.dart';

export 'vg_streaming_playback_client.dart'
    show VGStreamingFormatHint, VGStreamingNetworkProfile;
export 'vg_streaming_playback_status_summary.dart'
    show VGStreamingPlaybackStatusSummary;
export 'vg_streaming_preflight_client.dart' show VGStreamingPreflightReport;

/// Severity classification of the streaming playback session health.
enum VGStreamingPlaybackHealthSeverity {
  /// Playback is actively rendering with adequate buffer and no stall signals.
  healthy,

  /// Minor buffer depletion, normal startup/seek opening, or uninitialized session.
  watch,

  /// Recurring buffering or low buffer depth on degraded network conditions.
  degraded,

  /// Playhead is stalled on identical position despite active playback state.
  stalled,

  /// Session has reached a terminal state (recoverable error or non-recoverable completion/disposal).
  terminal;

  /// Serializes severity to lowercase string.
  String toJson() => name;
}

/// Advisory action recommended for host application UI or playback management.
enum VGStreamingPlaybackHealthAction {
  /// Current network profile and playback parameters are optimal.
  keepCurrentProfile,

  /// Connection has strong readahead; can utilize higher quality or stable profile.
  preferStableProfile,

  /// Bandwidth or buffer is constrained; recommend switching to constrained network profile.
  preferConstrainedProfile,

  /// Low-latency live tracking is causing rebuffering; recommend stepping back to standard/constrained profile.
  leaveLowLatency,

  /// Transient buffering or opening; recommend UI waiting for buffer to recover.
  waitForBuffer,

  /// Playback is stalled or suffered a recoverable error; recommend re-opening/retrying playback.
  retryPlayback,

  /// Stream ended normally, was disposed, or is unsupported; do not attempt automated retry.
  doNotRetryTerminal;

  /// Serializes action to lowercase string.
  String toJson() => name;
}

/// Immutable request configuration for streaming playback health evaluation.
class VGStreamingPlaybackHealthAdvisorRequest {
  /// Current playback status summary.
  final VGStreamingPlaybackStatusSummary current;

  /// Chronological recent playback status summaries leading up to [current] (oldest first).
  final List<VGStreamingPlaybackStatusSummary> recent;

  /// Optional preflight compatibility report for initial stream/device constraints.
  final VGStreamingPreflightReport? preflightReport;

  /// Active network profile applied to the playback session.
  final VGStreamingNetworkProfile currentNetworkProfile;

  /// Buffer percentage (0..100) below which the buffer is considered low.
  final int lowBufferPercentThreshold;

  /// Look-ahead buffer duration in milliseconds below which the buffer is considered low.
  final int lowBufferMsThreshold;

  /// Number of buffering samples in [recent] window indicating recurring rebuffering.
  final int repeatedBufferingCountThreshold;

  /// Consecutive samples with identical playhead position while playing indicating a stall.
  final int stalledPositionCountThreshold;

  const VGStreamingPlaybackHealthAdvisorRequest({
    required this.current,
    this.recent = const <VGStreamingPlaybackStatusSummary>[],
    this.preflightReport,
    this.currentNetworkProfile = VGStreamingNetworkProfile.auto,
    this.lowBufferPercentThreshold = 15,
    this.lowBufferMsThreshold = 2000,
    this.repeatedBufferingCountThreshold = 2,
    this.stalledPositionCountThreshold = 3,
  });

  /// Convenience factory for evaluating a single status summary.
  factory VGStreamingPlaybackHealthAdvisorRequest.fromCurrent(
    VGStreamingPlaybackStatusSummary current, {
    List<VGStreamingPlaybackStatusSummary> recent = const [],
    VGStreamingPreflightReport? preflightReport,
    VGStreamingNetworkProfile currentNetworkProfile =
        VGStreamingNetworkProfile.auto,
    int lowBufferPercentThreshold = 15,
    int lowBufferMsThreshold = 2000,
    int repeatedBufferingCountThreshold = 2,
    int stalledPositionCountThreshold = 3,
  }) => VGStreamingPlaybackHealthAdvisorRequest(
    current: current,
    recent: recent,
    preflightReport: preflightReport,
    currentNetworkProfile: currentNetworkProfile,
    lowBufferPercentThreshold: lowBufferPercentThreshold,
    lowBufferMsThreshold: lowBufferMsThreshold,
    repeatedBufferingCountThreshold: repeatedBufferingCountThreshold,
    stalledPositionCountThreshold: stalledPositionCountThreshold,
  );

  /// Serializes request to map for diagnostics and telemetry.
  Map<String, Object?> toJson() => <String, Object?>{
    'current': current.toJson(),
    'recentCount': recent.length,
    if (preflightReport != null)
      'preflightReport': preflightReport!.diagnostics,
    'currentNetworkProfile': currentNetworkProfile.toNative(),
    'lowBufferPercentThreshold': lowBufferPercentThreshold,
    'lowBufferMsThreshold': lowBufferMsThreshold,
    'repeatedBufferingCountThreshold': repeatedBufferingCountThreshold,
    'stalledPositionCountThreshold': stalledPositionCountThreshold,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackHealthAdvisorRequest(current=$current, '
      'profile=$currentNetworkProfile, recentCount=${recent.length})';
}

/// Immutable advisory recommendation produced by [VGStreamingPlaybackHealthAdvisor].
class VGStreamingPlaybackHealthAdvice {
  /// Overall health severity classification.
  final VGStreamingPlaybackHealthSeverity severity;

  /// Recommended high-level action for the host app.
  final VGStreamingPlaybackHealthAction recommendedAction;

  /// Recommended network profile policy for subsequent or ongoing playback.
  final VGStreamingNetworkProfile recommendedNetworkProfile;

  /// Whether the session should transition away from low-latency mode to avoid stalls.
  final bool shouldLeaveLowLatency;

  /// Whether playback recovery should be attempted (e.g. after recoverable failure or stall).
  final bool shouldRetry;

  /// Invariant: always `true` (pure advisory; zero player or session allocation).
  final bool advisoryOnly;

  /// Invariant: always `false` (zero playback mutation).
  final bool playbackMutation;

  /// Immutable list of rationale and warning codes that justified this advice.
  final List<String> reasons;

  /// Diagnostics dictionary containing evaluated telemetry metrics.
  final Map<String, Object?> diagnostics;

  /// Convenience alias for [reasons].
  List<String> get warnings => reasons;

  const VGStreamingPlaybackHealthAdvice({
    required this.severity,
    required this.recommendedAction,
    required this.recommendedNetworkProfile,
    required this.shouldLeaveLowLatency,
    required this.shouldRetry,
    this.advisoryOnly = true,
    this.playbackMutation = false,
    this.reasons = const <String>[],
    this.diagnostics = const <String, Object?>{},
  });

  /// Serializes advice to map.
  Map<String, Object?> toJson() => <String, Object?>{
    'severity': severity.name,
    'recommendedAction': recommendedAction.name,
    'recommendedNetworkProfile': recommendedNetworkProfile.toNative(),
    'shouldLeaveLowLatency': shouldLeaveLowLatency,
    'shouldRetry': shouldRetry,
    'advisoryOnly': advisoryOnly,
    'playbackMutation': playbackMutation,
    'reasons': reasons,
    'diagnostics': diagnostics,
  };

  @override
  String toString() =>
      'VGStreamingPlaybackHealthAdvice(severity=$severity, '
      'action=$recommendedAction, recommendedProfile=$recommendedNetworkProfile, '
      'shouldLeaveLowLatency=$shouldLeaveLowLatency, shouldRetry=$shouldRetry, '
      'reasons=$reasons)';
}

/// Pure Dart advisory helper for evaluating streaming playback health and poor-network mitigation.
abstract final class VGStreamingPlaybackHealthAdvisor {
  /// Evaluates [request] and produces an immutable [VGStreamingPlaybackHealthAdvice].
  static VGStreamingPlaybackHealthAdvice evaluate(
    VGStreamingPlaybackHealthAdvisorRequest request,
  ) {
    final current = request.current;
    final recent = request.recent;
    final preflight = request.preflightReport;
    final currentProfile = request.currentNetworkProfile;
    final isLowLatency = currentProfile == VGStreamingNetworkProfile.lowLatency;

    final reasons = <String>[];
    final diagnostics = <String, Object?>{
      'hasSession': current.hasSession,
      'isPlaying': current.isPlaying,
      'isBufferingOrOpening': current.isBufferingOrOpening,
      'isTerminal': current.isTerminal,
      'bufferedPercent': current.bufferedPercent,
      'bufferedPositionMs': current.bufferedPositionMs,
      'positionMs': current.positionMs,
      'currentNetworkProfile': currentProfile.toNative(),
      'recentCount': recent.length,
      'isLive': current.isLive,
    };

    // Preflight evaluation
    if (preflight != null) {
      diagnostics['preflightPass'] = preflight.pass;
      diagnostics['preflightDecision'] = preflight.advisoryDecision;
      if (!preflight.pass) {
        reasons.add('preflight_validation_failed');
        for (final w in preflight.warnings) {
          if (!reasons.contains(w)) {
            reasons.add(w);
          }
        }
      }
    }

    // 1. Terminal State evaluation (highest precedence)
    if (current.isTerminal) {
      final rawLower = current.raw.toLowerCase();
      final stateStr = (current.diagnostics['state']?.toString() ?? '')
          .toLowerCase();
      final isDisposed =
          rawLower.contains('disposed') || stateStr.contains('disposed');
      final isUnsupported =
          rawLower.contains('unsupported') || stateStr.contains('unsupported');
      final isEnded =
          (rawLower.contains('ended') || stateStr.contains('ended')) &&
          !rawLower.contains('failed');

      final isUnrecoverable = isDisposed || isUnsupported || isEnded;
      final isRecoverableFailure =
          !isUnrecoverable &&
          (rawLower.contains('failed') ||
              rawLower.contains('surfacelost') ||
              rawLower.contains('surface_lost') ||
              rawLower.contains('backgrounded') ||
              stateStr.contains('failed') ||
              stateStr.contains('surfacelost') ||
              stateStr.contains('backgrounded'));

      final VGStreamingPlaybackHealthAction action;
      final bool shouldRetry;

      if (isRecoverableFailure) {
        action = VGStreamingPlaybackHealthAction.retryPlayback;
        shouldRetry = true;
        reasons.add('terminal_recoverable_failure');
      } else {
        action = VGStreamingPlaybackHealthAction.doNotRetryTerminal;
        shouldRetry = false;
        if (isDisposed) {
          reasons.add('terminal_disposed');
        } else if (isUnsupported) {
          reasons.add('terminal_unsupported');
        } else if (isEnded) {
          reasons.add('terminal_ended');
        } else {
          reasons.add('terminal_non_recoverable');
        }
      }

      diagnostics['severity'] = VGStreamingPlaybackHealthSeverity.terminal.name;
      diagnostics['recommendedAction'] = action.name;
      diagnostics['shouldRetry'] = shouldRetry;
      diagnostics['advisoryOnly'] = true;
      diagnostics['playbackMutation'] = false;

      return VGStreamingPlaybackHealthAdvice(
        severity: VGStreamingPlaybackHealthSeverity.terminal,
        recommendedAction: action,
        recommendedNetworkProfile: currentProfile,
        shouldLeaveLowLatency: false,
        shouldRetry: shouldRetry,
        advisoryOnly: true,
        playbackMutation: false,
        reasons: List.unmodifiable(reasons),
        diagnostics: Map.unmodifiable(diagnostics),
      );
    }

    // 2. No Active Session (not terminal)
    if (!current.hasSession) {
      reasons.add('no_active_session');
      final recommendedProfile = (preflight != null && !preflight.pass)
          ? VGStreamingNetworkProfile.constrained
          : currentProfile;
      diagnostics['severity'] = VGStreamingPlaybackHealthSeverity.watch.name;
      diagnostics['recommendedAction'] =
          VGStreamingPlaybackHealthAction.keepCurrentProfile.name;
      diagnostics['shouldRetry'] = false;
      diagnostics['advisoryOnly'] = true;
      diagnostics['playbackMutation'] = false;

      return VGStreamingPlaybackHealthAdvice(
        severity: VGStreamingPlaybackHealthSeverity.watch,
        recommendedAction: VGStreamingPlaybackHealthAction.keepCurrentProfile,
        recommendedNetworkProfile: recommendedProfile,
        shouldLeaveLowLatency: false,
        shouldRetry: false,
        advisoryOnly: true,
        playbackMutation: false,
        reasons: List.unmodifiable(reasons),
        diagnostics: Map.unmodifiable(diagnostics),
      );
    }

    // 3. Active Session Telemetry Analysis
    // A. Low buffer
    final isLowBufferPercent =
        current.bufferedPercent <= request.lowBufferPercentThreshold;
    final isLowBufferMs =
        current.bufferedPositionMs > 0 &&
        current.bufferedPositionMs <= request.lowBufferMsThreshold;
    final isLowBuffer = isLowBufferPercent || isLowBufferMs;
    if (isLowBuffer) {
      reasons.add('low_buffer_depth');
    }

    // B. Buffering / Opening
    final isBuffering = current.isBufferingOrOpening;
    if (isBuffering) {
      reasons.add('currently_buffering_or_opening');
    }

    // C. Repeated buffering count across recent samples
    var recentBufferingCount = 0;
    for (final s in recent) {
      if (s.isBufferingOrOpening) {
        recentBufferingCount++;
      }
    }
    final totalBufferingCount = recentBufferingCount + (isBuffering ? 1 : 0);
    final hasRepeatedBuffering =
        totalBufferingCount >= request.repeatedBufferingCountThreshold;
    if (hasRepeatedBuffering) {
      reasons.add('repeated_buffering_detected');
    }
    diagnostics['bufferingCount'] = totalBufferingCount;

    // D. Stall check (repeated identical positions while playing)
    var samePositionCount = 0;
    if (recent.isNotEmpty && current.isPlaying) {
      for (var i = recent.length - 1; i >= 0; i--) {
        if (recent[i].positionMs == current.positionMs &&
            recent[i].isPlaying &&
            !recent[i].isBufferingOrOpening) {
          samePositionCount++;
        } else {
          break;
        }
      }
    }
    final isStalled =
        samePositionCount >= request.stalledPositionCountThreshold;
    if (isStalled) {
      reasons.add('playback_stalled_same_position');
    }
    diagnostics['stalledPositionCount'] = samePositionCount;

    // 4. Health & Action Arbitration
    final VGStreamingPlaybackHealthSeverity severity;
    final VGStreamingPlaybackHealthAction action;
    final VGStreamingNetworkProfile recommendedProfile;
    final bool shouldLeaveLowLatency;
    final bool shouldRetry;

    if (isLowLatency && (hasRepeatedBuffering || isLowBuffer || isStalled)) {
      // Low latency mode is struggling on degraded network
      severity = isStalled
          ? VGStreamingPlaybackHealthSeverity.stalled
          : VGStreamingPlaybackHealthSeverity.degraded;
      action = VGStreamingPlaybackHealthAction.leaveLowLatency;
      recommendedProfile = VGStreamingNetworkProfile.constrained;
      shouldLeaveLowLatency = true;
      shouldRetry = isStalled;
      reasons.add('leave_low_latency_for_constrained');
    } else if (isStalled) {
      // Position is stalled during active playback
      severity = VGStreamingPlaybackHealthSeverity.stalled;
      action = VGStreamingPlaybackHealthAction.retryPlayback;
      recommendedProfile = (currentProfile == VGStreamingNetworkProfile.stable)
          ? VGStreamingNetworkProfile.constrained
          : currentProfile;
      shouldLeaveLowLatency = false;
      shouldRetry = true;
    } else if (hasRepeatedBuffering) {
      // Recurring rebuffering in recent history
      severity = VGStreamingPlaybackHealthSeverity.degraded;
      action = VGStreamingPlaybackHealthAction.preferConstrainedProfile;
      recommendedProfile = VGStreamingNetworkProfile.constrained;
      shouldLeaveLowLatency = false;
      shouldRetry = false;
    } else if (isBuffering && isLowBuffer) {
      // Degraded: actively buffering with exhausted look-ahead
      severity = VGStreamingPlaybackHealthSeverity.degraded;
      action = VGStreamingPlaybackHealthAction.preferConstrainedProfile;
      recommendedProfile = VGStreamingNetworkProfile.constrained;
      shouldLeaveLowLatency = false;
      shouldRetry = false;
    } else if (isBuffering || isLowBuffer) {
      // Watch: buffer low or stream in initial/seek buffering
      severity = VGStreamingPlaybackHealthSeverity.watch;
      action = VGStreamingPlaybackHealthAction.waitForBuffer;
      recommendedProfile = (preflight != null && !preflight.pass)
          ? VGStreamingNetworkProfile.constrained
          : currentProfile;
      shouldLeaveLowLatency = false;
      shouldRetry = false;
    } else {
      // Healthy playback with adequate buffer
      if (preflight != null && !preflight.pass) {
        severity = VGStreamingPlaybackHealthSeverity.watch;
        action = VGStreamingPlaybackHealthAction.preferConstrainedProfile;
        recommendedProfile = VGStreamingNetworkProfile.constrained;
      } else {
        severity = VGStreamingPlaybackHealthSeverity.healthy;
        action =
            (currentProfile == VGStreamingNetworkProfile.auto &&
                preflight?.recommendedNetworkProfile == 'STABLE')
            ? VGStreamingPlaybackHealthAction.preferStableProfile
            : VGStreamingPlaybackHealthAction.keepCurrentProfile;
        recommendedProfile =
            (preflight?.recommendedNetworkProfile == 'STABLE' &&
                currentProfile == VGStreamingNetworkProfile.auto)
            ? VGStreamingNetworkProfile.stable
            : currentProfile;
      }
      shouldLeaveLowLatency = false;
      shouldRetry = false;
    }

    diagnostics['severity'] = severity.name;
    diagnostics['recommendedAction'] = action.name;
    diagnostics['recommendedNetworkProfile'] = recommendedProfile.toNative();
    diagnostics['shouldLeaveLowLatency'] = shouldLeaveLowLatency;
    diagnostics['shouldRetry'] = shouldRetry;
    diagnostics['advisoryOnly'] = true;
    diagnostics['playbackMutation'] = false;

    return VGStreamingPlaybackHealthAdvice(
      severity: severity,
      recommendedAction: action,
      recommendedNetworkProfile: recommendedProfile,
      shouldLeaveLowLatency: shouldLeaveLowLatency,
      shouldRetry: shouldRetry,
      advisoryOnly: true,
      playbackMutation: false,
      reasons: List.unmodifiable(reasons),
      diagnostics: Map.unmodifiable(diagnostics),
    );
  }
}
