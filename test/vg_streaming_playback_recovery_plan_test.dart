// Copyright (c) Connects — Vanguard Phase 4C7AK.
// Public streaming playback recovery plan unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackRecoveryPlanner', () {
    // Helper to create a basic test status summary
    VGStreamingPlaybackStatusSummary createSummary({
      bool hasSession = true,
      bool isPlaying = true,
      bool isBufferingOrOpening = false,
      bool isTerminal = false,
      bool isLive = false,
      int positionMs = 12500,
      int bufferedPositionMs = 25000,
      int bufferedPercent = 80,
      String raw = 'status=OK',
      Map<String, Object?> diagnostics = const {},
    }) {
      return VGStreamingPlaybackStatusSummary(
        hasSession: hasSession,
        isLive: isLive,
        isSeekable: !isLive,
        isPlaying: isPlaying,
        isBufferingOrOpening: isBufferingOrOpening,
        isTerminal: isTerminal,
        durationMs: isLive ? -1 : 60000,
        positionMs: positionMs,
        bufferedPositionMs: bufferedPositionMs,
        bufferedPercent: bufferedPercent,
        progressFraction: isLive ? 0.0 : (positionMs / 60000.0),
        bufferedFraction: bufferedPercent / 100.0,
        effectiveDisplayWidth: 1920,
        effectiveDisplayHeight: 1080,
        hasRotationMetadata: false,
        playbackCacheEnabled: true,
        playbackCacheTelemetryAttached: true,
        playbackCacheReadObserved: true,
        playbackCacheBytesRead: 1024,
        playbackCacheSizeBytes: 2048,
        playbackCacheIgnoredCount: 0,
        raw: raw,
        diagnostics: diagnostics,
      );
    }

    // Helper to create standard mock playback options
    VGStreamingPlaybackOptions createOptions({
      VGStreamingNetworkProfile networkProfile = VGStreamingNetworkProfile.auto,
      VGStreamingFormatHint formatHint = VGStreamingFormatHint.hls,
      int? initialPositionMs,
      bool cacheEnabled = true,
    }) {
      return VGStreamingPlaybackOptions(
        uri: Uri.parse('https://cdn.example.com/live/master.m3u8'),
        initialWidth: 1080,
        initialHeight: 1920,
        httpHeaders: const {'Authorization': 'Bearer token123'},
        formatHint: formatHint,
        networkProfile: networkProfile,
        autoPlay: true,
        initialPositionMs: initialPositionMs,
        cacheOptions: cacheEnabled
            ? const VGPlaybackCacheOptions(
                cacheEnabled: true,
                cacheMaxBytes: 256 * 1024 * 1024,
              )
            : null,
      );
    }

    // Helper to create mock advice
    VGStreamingPlaybackHealthAdvice createAdvice({
      VGStreamingPlaybackHealthSeverity severity =
          VGStreamingPlaybackHealthSeverity.healthy,
      VGStreamingPlaybackHealthAction action =
          VGStreamingPlaybackHealthAction.keepCurrentProfile,
      VGStreamingNetworkProfile profile = VGStreamingNetworkProfile.auto,
      bool shouldLeaveLowLatency = false,
      bool shouldRetry = false,
      List<String> reasons = const [],
    }) {
      return VGStreamingPlaybackHealthAdvice(
        severity: severity,
        recommendedAction: action,
        recommendedNetworkProfile: profile,
        shouldLeaveLowLatency: shouldLeaveLowLatency,
        shouldRetry: shouldRetry,
        advisoryOnly: true,
        playbackMutation: false,
        reasons: reasons,
      );
    }

    test('1. Invariants hold across all recovery plan evaluations', () {
      final advice = createAdvice();
      final request = VGStreamingPlaybackRecoveryPlanRequest(advice: advice);
      final plan = VGStreamingPlaybackRecoveryPlanner.plan(request);

      expect(plan.advisoryOnly, isTrue);
      expect(plan.playbackMutation, isFalse);
      expect(plan.diagnostics['advisoryOnly'], isTrue);
      expect(plan.diagnostics['playbackMutation'], isFalse);
    });

    test('2. Healthy advice with keepCurrentProfile yields none intent', () {
      final advice = createAdvice(
        severity: VGStreamingPlaybackHealthSeverity.healthy,
        action: VGStreamingPlaybackHealthAction.keepCurrentProfile,
        profile: VGStreamingNetworkProfile.auto,
        reasons: ['buffer_healthy'],
      );
      final options = createOptions();
      final summary = createSummary();

      final request = VGStreamingPlaybackRecoveryPlanRequest(
        advice: advice,
        currentOptions: options,
        currentStatus: summary,
      );
      final plan = VGStreamingPlaybackRecoveryPlanner.plan(request);

      expect(plan.intent, equals(VGStreamingPlaybackRecoveryIntent.none));
      expect(plan.urgency, equals(VGStreamingPlaybackRecoveryUrgency.none));
      expect(plan.shouldReopenPlayback, isFalse);
      expect(plan.requiresHostAction, isFalse);
      expect(plan.canBuildPlaybackOptions, isFalse);
      expect(plan.playbackOptions, isNull);
      expect(plan.resumePositionMs, isNull);
      expect(plan.reasons, contains('buffer_healthy'));
      expect(plan.reasons, contains('keep_current_profile_optimal'));
    });

    test(
      '3. preferStableProfile: builds optional profile without forcing action',
      () {
        final advice = createAdvice(
          severity: VGStreamingPlaybackHealthSeverity.healthy,
          action: VGStreamingPlaybackHealthAction.preferStableProfile,
          profile: VGStreamingNetworkProfile.stable,
          reasons: ['readahead_high'],
        );
        final options = createOptions(
          networkProfile: VGStreamingNetworkProfile.auto,
        );

        // 3a. Without allowAutomaticRetry -> intent is none, urgency is passive, no reopen
        final reqManual = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: options,
          allowAutomaticRetry: false,
        );
        final planManual = VGStreamingPlaybackRecoveryPlanner.plan(reqManual);

        expect(
          planManual.intent,
          equals(VGStreamingPlaybackRecoveryIntent.none),
        );
        expect(
          planManual.urgency,
          equals(VGStreamingPlaybackRecoveryUrgency.passive),
        );
        expect(planManual.shouldReopenPlayback, isFalse);
        expect(planManual.requiresHostAction, isFalse);
        expect(planManual.canBuildPlaybackOptions, isTrue);
        expect(planManual.playbackOptions, isNotNull);
        expect(
          planManual.playbackOptions!.networkProfile,
          equals(VGStreamingNetworkProfile.stable),
        );

        // 3b. With allowAutomaticRetry -> intent is retryCurrentProfile
        final reqAuto = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: options,
          allowAutomaticRetry: true,
        );
        final planAuto = VGStreamingPlaybackRecoveryPlanner.plan(reqAuto);

        expect(
          planAuto.intent,
          equals(VGStreamingPlaybackRecoveryIntent.retryCurrentProfile),
        );
        expect(
          planAuto.urgency,
          equals(VGStreamingPlaybackRecoveryUrgency.passive),
        );
        expect(planAuto.shouldReopenPlayback, isFalse);
        expect(planAuto.requiresHostAction, isFalse);

        // 3c. Without currentOptions -> canBuildPlaybackOptions is false
        final reqNoOpt = VGStreamingPlaybackRecoveryPlanRequest(advice: advice);
        final planNoOpt = VGStreamingPlaybackRecoveryPlanner.plan(reqNoOpt);
        expect(planNoOpt.canBuildPlaybackOptions, isFalse);
        expect(planNoOpt.playbackOptions, isNull);
      },
    );

    test('4. waitForBuffer: passive delay without reopening', () {
      final advice = createAdvice(
        severity: VGStreamingPlaybackHealthSeverity.watch,
        action: VGStreamingPlaybackHealthAction.waitForBuffer,
        profile: VGStreamingNetworkProfile.auto,
        reasons: ['low_buffer_depth'],
      );
      final options = createOptions();

      final request = VGStreamingPlaybackRecoveryPlanRequest(
        advice: advice,
        currentOptions: options,
      );
      final plan = VGStreamingPlaybackRecoveryPlanner.plan(request);

      expect(
        plan.intent,
        equals(VGStreamingPlaybackRecoveryIntent.waitForBuffer),
      );
      expect(plan.urgency, equals(VGStreamingPlaybackRecoveryUrgency.passive));
      expect(plan.shouldReopenPlayback, isFalse);
      expect(plan.requiresHostAction, isFalse);
      expect(plan.canBuildPlaybackOptions, isFalse);
      expect(plan.playbackOptions, isNull);
      expect(plan.reasons, contains('wait_for_buffer_recovery'));
    });

    test(
      '5. preferConstrainedProfile: builds constrained options with active urgency',
      () {
        final advice = createAdvice(
          severity: VGStreamingPlaybackHealthSeverity.degraded,
          action: VGStreamingPlaybackHealthAction.preferConstrainedProfile,
          profile: VGStreamingNetworkProfile.constrained,
          reasons: ['repeated_buffering_detected'],
        );
        final options = createOptions(
          networkProfile: VGStreamingNetworkProfile.auto,
        );

        // With options
        final reqWithOptions = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: options,
        );
        final planWithOptions = VGStreamingPlaybackRecoveryPlanner.plan(
          reqWithOptions,
        );

        expect(
          planWithOptions.intent,
          equals(VGStreamingPlaybackRecoveryIntent.retryConstrainedProfile),
        );
        expect(
          planWithOptions.urgency,
          equals(VGStreamingPlaybackRecoveryUrgency.active),
        );
        expect(planWithOptions.shouldReopenPlayback, isTrue);
        expect(planWithOptions.canBuildPlaybackOptions, isTrue);
        expect(
          planWithOptions.playbackOptions!.networkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(
          planWithOptions.requiresHostAction,
          isTrue,
        ); // host owns action when allowAutoRetry is false
        expect(planWithOptions.advisoryOnly, isTrue);
        expect(planWithOptions.playbackMutation, isFalse);

        // With allowAutomaticRetry = true
        final reqAuto = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: options,
          allowAutomaticRetry: true,
        );
        final planAuto = VGStreamingPlaybackRecoveryPlanner.plan(reqAuto);
        expect(planAuto.shouldReopenPlayback, isTrue);
        expect(planAuto.requiresHostAction, isFalse);
        expect(planAuto.advisoryOnly, isTrue);
        expect(planAuto.playbackMutation, isFalse);

        // Without options -> requires host action and cannot build options
        final reqNoOptions = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
        );
        final planNoOptions = VGStreamingPlaybackRecoveryPlanner.plan(
          reqNoOptions,
        );

        expect(planNoOptions.shouldReopenPlayback, isTrue);
        expect(planNoOptions.canBuildPlaybackOptions, isFalse);
        expect(planNoOptions.playbackOptions, isNull);
        expect(planNoOptions.requiresHostAction, isTrue);
        expect(planNoOptions.advisoryOnly, isTrue);
        expect(planNoOptions.playbackMutation, isFalse);
      },
    );

    test(
      '6. leaveLowLatency: requires reopening to standard latency with constrained profile',
      () {
        final advice = createAdvice(
          severity: VGStreamingPlaybackHealthSeverity.degraded,
          action: VGStreamingPlaybackHealthAction.leaveLowLatency,
          profile: VGStreamingNetworkProfile.constrained,
          shouldLeaveLowLatency: true,
          reasons: ['leave_low_latency_for_constrained'],
        );
        final options = createOptions(
          networkProfile: VGStreamingNetworkProfile.lowLatency,
        );
        final summary = createSummary(isLive: true, positionMs: 35000);

        final request = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: options,
          currentStatus: summary,
        );
        final plan = VGStreamingPlaybackRecoveryPlanner.plan(request);

        expect(
          plan.intent,
          equals(VGStreamingPlaybackRecoveryIntent.reopenStandardLatency),
        );
        expect(
          plan.urgency,
          equals(VGStreamingPlaybackRecoveryUrgency.immediate),
        );
        expect(plan.shouldReopenPlayback, isTrue);
        expect(plan.requiresHostAction, isTrue);
        expect(plan.canBuildPlaybackOptions, isTrue);
        expect(
          plan.playbackOptions!.networkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        // For live streams, initialPositionMs remains null to track live edge
        expect(plan.resumePositionMs, isNull);
        expect(plan.playbackOptions!.initialPositionMs, isNull);
        expect(plan.reasons, contains('leave_low_latency_reopen_constrained'));
      },
    );

    test(
      '7. retryPlayback: stalled session plans immediate reopen and resumes VOD position',
      () {
        final advice = createAdvice(
          severity: VGStreamingPlaybackHealthSeverity.stalled,
          action: VGStreamingPlaybackHealthAction.retryPlayback,
          profile: VGStreamingNetworkProfile.constrained,
          shouldRetry: true,
          reasons: ['playback_stalled_same_position'],
        );
        final options = createOptions(
          networkProfile: VGStreamingNetworkProfile.stable,
        );
        final vodSummary = createSummary(isLive: false, positionMs: 24000);

        final request = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: options,
          currentStatus: vodSummary,
          allowAutomaticRetry: false,
          retryDelayMs: 1000,
        );
        final plan = VGStreamingPlaybackRecoveryPlanner.plan(request);

        expect(
          plan.intent,
          equals(VGStreamingPlaybackRecoveryIntent.retryCurrentProfile),
        );
        expect(
          plan.urgency,
          equals(VGStreamingPlaybackRecoveryUrgency.immediate),
        );
        expect(plan.shouldReopenPlayback, isTrue);
        expect(plan.requiresHostAction, isTrue); // allowAutomaticRetry is false
        expect(plan.canBuildPlaybackOptions, isTrue);
        expect(plan.resumePositionMs, equals(24000));
        expect(plan.playbackOptions!.initialPositionMs, equals(24000));
        expect(
          plan.playbackOptions!.networkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(plan.retryDelayMs, equals(1000));
      },
    );

    test(
      '8. retryPlayback with allowAutomaticRetry = true marks requiresHostAction = false',
      () {
        final advice = createAdvice(
          severity: VGStreamingPlaybackHealthSeverity.stalled,
          action: VGStreamingPlaybackHealthAction.retryPlayback,
          profile: VGStreamingNetworkProfile.auto,
          shouldRetry: true,
        );
        final options = createOptions();

        final request = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: options,
          allowAutomaticRetry: true,
        );
        final plan = VGStreamingPlaybackRecoveryPlanner.plan(request);

        expect(plan.shouldReopenPlayback, isTrue);
        expect(plan.requiresHostAction, isFalse);
        expect(plan.canBuildPlaybackOptions, isTrue);
      },
    );

    test(
      '9. resumePositionOverrideMs overrides VOD and Live stream resume positions',
      () {
        final advice = createAdvice(
          severity: VGStreamingPlaybackHealthSeverity.terminal,
          action: VGStreamingPlaybackHealthAction.retryPlayback,
          profile: VGStreamingNetworkProfile.auto,
          shouldRetry: true,
        );
        final options = createOptions();
        final liveSummary = createSummary(isLive: true, positionMs: 50000);

        final request = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: options,
          currentStatus: liveSummary,
          resumePositionOverrideMs: 42000,
        );
        final plan = VGStreamingPlaybackRecoveryPlanner.plan(request);

        expect(plan.resumePositionMs, equals(42000));
        expect(plan.playbackOptions!.initialPositionMs, equals(42000));
      },
    );

    test('10. doNotRetryTerminal: stops terminal playback cleanly', () {
      final advice = createAdvice(
        severity: VGStreamingPlaybackHealthSeverity.terminal,
        action: VGStreamingPlaybackHealthAction.doNotRetryTerminal,
        profile: VGStreamingNetworkProfile.auto,
        shouldRetry: false,
        reasons: ['terminal_disposed'],
      );
      final options = createOptions();

      final request = VGStreamingPlaybackRecoveryPlanRequest(
        advice: advice,
        currentOptions: options,
      );
      final plan = VGStreamingPlaybackRecoveryPlanner.plan(request);

      expect(
        plan.intent,
        equals(VGStreamingPlaybackRecoveryIntent.stopTerminal),
      );
      expect(plan.urgency, equals(VGStreamingPlaybackRecoveryUrgency.none));
      expect(plan.shouldReopenPlayback, isFalse);
      expect(plan.requiresHostAction, isFalse);
      expect(plan.canBuildPlaybackOptions, isFalse);
      expect(plan.playbackOptions, isNull);
      expect(plan.reasons, contains('terminal_disposed'));
      expect(plan.reasons, contains('terminal_do_not_retry'));
    });

    test(
      '11. Option cloning preserves HTTP headers, dimensions, formatHint, and cache settings',
      () {
        final advice = createAdvice(
          severity: VGStreamingPlaybackHealthSeverity.degraded,
          action: VGStreamingPlaybackHealthAction.preferConstrainedProfile,
          profile: VGStreamingNetworkProfile.constrained,
        );

        final sourceOptions = VGStreamingPlaybackOptions(
          uri: Uri.parse('https://example.com/custom_path/index.mpd'),
          initialWidth: 720,
          initialHeight: 1280,
          httpHeaders: const {'X-Custom-Token': 'secret99'},
          formatHint: VGStreamingFormatHint.dash,
          networkProfile: VGStreamingNetworkProfile.auto,
          autoPlay: false,
          cacheOptions: const VGPlaybackCacheOptions(
            cacheEnabled: true,
            cacheMaxBytes: 128 * 1024 * 1024,
            cacheDirectoryName: 'custom_cache_dir',
          ),
        );

        // Preserving cache options (default)
        final reqPreserve = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: sourceOptions,
          preserveCacheOptions: true,
        );
        final planPreserve = VGStreamingPlaybackRecoveryPlanner.plan(
          reqPreserve,
        );
        final clonedPreserve = planPreserve.playbackOptions!;

        expect(clonedPreserve.uri, equals(sourceOptions.uri));
        expect(clonedPreserve.initialWidth, equals(720));
        expect(clonedPreserve.initialHeight, equals(1280));
        expect(
          clonedPreserve.httpHeaders,
          equals({'X-Custom-Token': 'secret99'}),
        );
        expect(clonedPreserve.formatHint, equals(VGStreamingFormatHint.dash));
        expect(clonedPreserve.autoPlay, isFalse);
        expect(
          clonedPreserve.networkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(clonedPreserve.cacheOptions, isNotNull);
        expect(
          clonedPreserve.cacheOptions!.cacheDirectoryName,
          equals('custom_cache_dir'),
        );

        // Stripping cache options
        final reqStrip = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: sourceOptions,
          preserveCacheOptions: false,
        );
        final planStrip = VGStreamingPlaybackRecoveryPlanner.plan(reqStrip);
        expect(planStrip.playbackOptions!.cacheOptions, isNull);
      },
    );

    test(
      '12. Serialization and toString work properly for request, plan, and enums',
      () {
        final advice = createAdvice(
          severity: VGStreamingPlaybackHealthSeverity.stalled,
          action: VGStreamingPlaybackHealthAction.retryPlayback,
          profile: VGStreamingNetworkProfile.constrained,
          shouldRetry: true,
          reasons: ['stalled_buffer'],
        );
        final options = createOptions();
        final summary = createSummary();

        final request = VGStreamingPlaybackRecoveryPlanRequest(
          advice: advice,
          currentOptions: options,
          currentStatus: summary,
          allowAutomaticRetry: true,
          retryDelayMs: 500,
          resumePositionOverrideMs: 1000,
        );

        final reqJson = request.toJson();
        expect(reqJson['allowAutomaticRetry'], isTrue);
        expect(reqJson['retryDelayMs'], equals(500));
        expect(reqJson['resumePositionOverrideMs'], equals(1000));
        expect(reqJson['preserveCacheOptions'], isTrue);
        expect(
          request.toString(),
          contains('VGStreamingPlaybackRecoveryPlanRequest'),
        );

        final plan = VGStreamingPlaybackRecoveryPlanner.plan(request);
        final planJson = plan.toJson();
        expect(planJson['intent'], equals('retryCurrentProfile'));
        expect(planJson['urgency'], equals('immediate'));
        expect(planJson['shouldReopenPlayback'], isTrue);
        expect(planJson['requiresHostAction'], isFalse);
        expect(planJson['canBuildPlaybackOptions'], isTrue);
        expect(planJson['resumePositionMs'], equals(1000));
        expect(planJson['retryDelayMs'], equals(500));
        expect(planJson['advisoryOnly'], isTrue);
        expect(planJson['playbackMutation'], isFalse);
        expect(planJson['reasons'], contains('stalled_buffer'));
        expect(plan.toString(), contains('VGStreamingPlaybackRecoveryPlan'));
        expect(plan.warnings, equals(plan.reasons));

        // Enum toJson
        expect(
          VGStreamingPlaybackRecoveryIntent.retryConstrainedProfile.toJson(),
          equals('retryConstrainedProfile'),
        );
        expect(
          VGStreamingPlaybackRecoveryUrgency.immediate.toJson(),
          equals('immediate'),
        );
      },
    );
  });
}
