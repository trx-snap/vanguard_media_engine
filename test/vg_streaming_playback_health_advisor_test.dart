// Copyright (c) Connects — Vanguard Phase 4C7AI.
// Public streaming playback health advisor unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackHealthAdvisor', () {
    // Helper to create a basic mock status summary
    VGStreamingPlaybackStatusSummary createSummary({
      bool hasSession = true,
      bool isPlaying = true,
      bool isBufferingOrOpening = false,
      bool isTerminal = false,
      bool isLive = false,
      int positionMs = 5000,
      int bufferedPositionMs = 15000,
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
        playbackCacheEnabled: false,
        playbackCacheTelemetryAttached: false,
        playbackCacheReadObserved: false,
        playbackCacheBytesRead: 0,
        playbackCacheSizeBytes: 0,
        playbackCacheIgnoredCount: 0,
        raw: raw,
        diagnostics: diagnostics,
      );
    }

    test('1. Invariants hold across all advice evaluations', () {
      final summary = createSummary();
      final request = VGStreamingPlaybackHealthAdvisorRequest(current: summary);
      final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);

      expect(advice.advisoryOnly, isTrue);
      expect(advice.playbackMutation, isFalse);
      expect(advice.diagnostics['advisoryOnly'], isTrue);
      expect(advice.diagnostics['playbackMutation'], isFalse);
    });

    test('2. Healthy playing state with adequate buffer', () {
      final summary = createSummary(
        isPlaying: true,
        isBufferingOrOpening: false,
        bufferedPercent: 85,
        bufferedPositionMs: 25000,
      );
      final request = VGStreamingPlaybackHealthAdvisorRequest(
        current: summary,
        currentNetworkProfile: VGStreamingNetworkProfile.stable,
      );

      final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);

      expect(
        advice.severity,
        equals(VGStreamingPlaybackHealthSeverity.healthy),
      );
      expect(
        advice.recommendedAction,
        equals(VGStreamingPlaybackHealthAction.keepCurrentProfile),
      );
      expect(
        advice.recommendedNetworkProfile,
        equals(VGStreamingNetworkProfile.stable),
      );
      expect(advice.shouldLeaveLowLatency, isFalse);
      expect(advice.shouldRetry, isFalse);
    });

    test(
      '3. Healthy session with preflight stable recommendation upgrades auto profile',
      () {
        final summary = createSummary(
          isPlaying: true,
          bufferedPercent: 90,
          bufferedPositionMs: 30000,
        );
        const preflight = VGStreamingPreflightReport(
          pass: true,
          phase: 'Phase4C5G',
          advisoryDecision: 'advise_stable',
          requestedNetworkProfile: 'AUTO',
          recommendedNetworkProfile: 'STABLE',
          recommendedNetworkPolicy: {'profile': 'STABLE'},
          totalReports: 1,
          passedReports: 1,
          failedReports: 0,
          warnings: [],
          deviceWarnings: [],
          llHlsAvailable: false,
          advisoryOnly: true,
          playbackMutation: false,
          serverLadderPolicy: 'ladder_ok',
          iosMirrorNote: '',
          raw: 'status=OK',
          diagnostics: {},
        );

        final request = VGStreamingPlaybackHealthAdvisorRequest(
          current: summary,
          currentNetworkProfile: VGStreamingNetworkProfile.auto,
          preflightReport: preflight,
        );

        final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);

        expect(
          advice.severity,
          equals(VGStreamingPlaybackHealthSeverity.healthy),
        );
        expect(
          advice.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.preferStableProfile),
        );
        expect(
          advice.recommendedNetworkProfile,
          equals(VGStreamingNetworkProfile.stable),
        );
      },
    );

    test('4. Low buffer depth triggers watch or degraded status', () {
      // 4a: Playing with low buffer percentage
      final lowPercentSummary = createSummary(
        isPlaying: true,
        bufferedPercent: 10, // below default 15%
        bufferedPositionMs: 1500,
      );
      final request1 = VGStreamingPlaybackHealthAdvisorRequest(
        current: lowPercentSummary,
      );
      final advice1 = VGStreamingPlaybackHealthAdvisor.evaluate(request1);

      expect(advice1.severity, equals(VGStreamingPlaybackHealthSeverity.watch));
      expect(
        advice1.recommendedAction,
        equals(VGStreamingPlaybackHealthAction.waitForBuffer),
      );
      expect(advice1.reasons, contains('low_buffer_depth'));

      // 4b: Actively buffering with exhausted look-ahead buffer
      final bufferingExhausted = createSummary(
        isPlaying: false,
        isBufferingOrOpening: true,
        bufferedPercent: 5,
        bufferedPositionMs: 500,
      );
      final request2 = VGStreamingPlaybackHealthAdvisorRequest(
        current: bufferingExhausted,
      );
      final advice2 = VGStreamingPlaybackHealthAdvisor.evaluate(request2);

      expect(
        advice2.severity,
        equals(VGStreamingPlaybackHealthSeverity.degraded),
      );
      expect(
        advice2.recommendedAction,
        equals(VGStreamingPlaybackHealthAction.preferConstrainedProfile),
      );
      expect(
        advice2.recommendedNetworkProfile,
        equals(VGStreamingNetworkProfile.constrained),
      );
      expect(advice2.reasons, contains('currently_buffering_or_opening'));
      expect(advice2.reasons, contains('low_buffer_depth'));
    });

    test(
      '5. Repeated buffering in recent history advises constrained profile',
      () {
        final recent = [
          createSummary(isPlaying: false, isBufferingOrOpening: true),
          createSummary(isPlaying: true, isBufferingOrOpening: false),
          createSummary(isPlaying: false, isBufferingOrOpening: true),
        ];
        final current = createSummary(
          isPlaying: true,
          isBufferingOrOpening: false,
          bufferedPercent: 50,
        );

        final request = VGStreamingPlaybackHealthAdvisorRequest(
          current: current,
          recent: recent,
          currentNetworkProfile: VGStreamingNetworkProfile.auto,
        );
        final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);

        expect(
          advice.severity,
          equals(VGStreamingPlaybackHealthSeverity.degraded),
        );
        expect(
          advice.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.preferConstrainedProfile),
        );
        expect(
          advice.recommendedNetworkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(advice.reasons, contains('repeated_buffering_detected'));
      },
    );

    test(
      '6. Low latency profile under poor network triggers leaveLowLatency',
      () {
        final current = createSummary(
          isPlaying: true,
          isBufferingOrOpening: true,
          bufferedPercent: 8,
          bufferedPositionMs: 800,
          isLive: true,
        );
        final request = VGStreamingPlaybackHealthAdvisorRequest(
          current: current,
          currentNetworkProfile: VGStreamingNetworkProfile.lowLatency,
        );
        final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);

        expect(
          advice.severity,
          equals(VGStreamingPlaybackHealthSeverity.degraded),
        );
        expect(
          advice.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.leaveLowLatency),
        );
        expect(advice.shouldLeaveLowLatency, isTrue);
        expect(
          advice.recommendedNetworkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(advice.reasons, contains('leave_low_latency_for_constrained'));
      },
    );

    test(
      '7. Playhead stalled on same position during playback triggers stall retry',
      () {
        final recent = [
          createSummary(positionMs: 12000, isPlaying: true),
          createSummary(positionMs: 12000, isPlaying: true),
          createSummary(positionMs: 12000, isPlaying: true),
        ];
        final current = createSummary(positionMs: 12000, isPlaying: true);

        final request = VGStreamingPlaybackHealthAdvisorRequest(
          current: current,
          recent: recent,
          currentNetworkProfile: VGStreamingNetworkProfile.stable,
        );
        final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);

        expect(
          advice.severity,
          equals(VGStreamingPlaybackHealthSeverity.stalled),
        );
        expect(
          advice.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.retryPlayback),
        );
        expect(advice.shouldRetry, isTrue);
        expect(
          advice.recommendedNetworkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(advice.reasons, contains('playback_stalled_same_position'));
      },
    );

    test(
      '8. Stalled low-latency session prioritizes leaving low latency with retry',
      () {
        final recent = [
          createSummary(positionMs: 8000, isPlaying: true),
          createSummary(positionMs: 8000, isPlaying: true),
          createSummary(positionMs: 8000, isPlaying: true),
        ];
        final current = createSummary(
          positionMs: 8000,
          isPlaying: true,
          isLive: true,
        );

        final request = VGStreamingPlaybackHealthAdvisorRequest(
          current: current,
          recent: recent,
          currentNetworkProfile: VGStreamingNetworkProfile.lowLatency,
        );
        final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);

        expect(
          advice.severity,
          equals(VGStreamingPlaybackHealthSeverity.stalled),
        );
        expect(
          advice.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.leaveLowLatency),
        );
        expect(advice.shouldLeaveLowLatency, isTrue);
        expect(advice.shouldRetry, isTrue);
        expect(
          advice.recommendedNetworkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
      },
    );

    test('9. Terminal state: recoverable failure signals retry', () {
      final recoverableSummary = createSummary(
        isPlaying: false,
        isTerminal: true,
        raw: 'state=failed;error=decoder_reset_needed',
        diagnostics: {'state': 'failed'},
      );
      final request = VGStreamingPlaybackHealthAdvisorRequest(
        current: recoverableSummary,
      );
      final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);

      expect(
        advice.severity,
        equals(VGStreamingPlaybackHealthSeverity.terminal),
      );
      expect(
        advice.recommendedAction,
        equals(VGStreamingPlaybackHealthAction.retryPlayback),
      );
      expect(advice.shouldRetry, isTrue);
      expect(advice.reasons, contains('terminal_recoverable_failure'));

      // Surface lost
      final surfaceLostSummary = createSummary(
        isPlaying: false,
        isTerminal: true,
        raw: 'state=surfaceLost;cleanup',
        diagnostics: {'state': 'surfaceLost'},
      );
      final adviceSurface = VGStreamingPlaybackHealthAdvisor.evaluate(
        VGStreamingPlaybackHealthAdvisorRequest(current: surfaceLostSummary),
      );
      expect(adviceSurface.shouldRetry, isTrue);
      expect(
        adviceSurface.recommendedAction,
        equals(VGStreamingPlaybackHealthAction.retryPlayback),
      );
    });

    test(
      '10. Terminal state: disposed or unsupported signals doNotRetryTerminal',
      () {
        // Disposed
        final disposedSummary = createSummary(
          isPlaying: false,
          isTerminal: true,
          raw: 'state=disposed',
          diagnostics: {'state': 'disposed'},
        );
        final adviceDisposed = VGStreamingPlaybackHealthAdvisor.evaluate(
          VGStreamingPlaybackHealthAdvisorRequest(current: disposedSummary),
        );
        expect(
          adviceDisposed.severity,
          equals(VGStreamingPlaybackHealthSeverity.terminal),
        );
        expect(
          adviceDisposed.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.doNotRetryTerminal),
        );
        expect(adviceDisposed.shouldRetry, isFalse);
        expect(adviceDisposed.reasons, contains('terminal_disposed'));

        // Unsupported
        final unsupportedSummary = createSummary(
          isPlaying: false,
          isTerminal: true,
          raw: 'status=UNSUPPORTED',
          diagnostics: {'state': 'unsupported'},
        );
        final adviceUnsupported = VGStreamingPlaybackHealthAdvisor.evaluate(
          VGStreamingPlaybackHealthAdvisorRequest(current: unsupportedSummary),
        );
        expect(adviceUnsupported.shouldRetry, isFalse);
        expect(
          adviceUnsupported.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.doNotRetryTerminal),
        );
        expect(adviceUnsupported.reasons, contains('terminal_unsupported'));

        // Ended
        final endedSummary = createSummary(
          isPlaying: false,
          isTerminal: true,
          raw: 'state=ended',
          diagnostics: {'state': 'ended'},
        );
        final adviceEnded = VGStreamingPlaybackHealthAdvisor.evaluate(
          VGStreamingPlaybackHealthAdvisorRequest(current: endedSummary),
        );
        expect(adviceEnded.shouldRetry, isFalse);
        expect(
          adviceEnded.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.doNotRetryTerminal),
        );
        expect(adviceEnded.reasons, contains('terminal_ended'));
      },
    );

    test(
      '11. Preflight failure adds warnings and biases profile but preserves terminal precedence',
      () {
        const failedPreflight = VGStreamingPreflightReport(
          pass: false,
          phase: 'Phase4C5G',
          advisoryDecision: 'advise_constrained',
          requestedNetworkProfile: 'AUTO',
          recommendedNetworkProfile: 'CONSTRAINED',
          recommendedNetworkPolicy: {'profile': 'CONSTRAINED'},
          totalReports: 1,
          passedReports: 0,
          failedReports: 1,
          warnings: ['bandwidth_too_low'],
          deviceWarnings: [],
          llHlsAvailable: false,
          advisoryOnly: true,
          playbackMutation: false,
          serverLadderPolicy: '',
          iosMirrorNote: '',
          raw: 'status=FAILED',
          diagnostics: {},
        );

        // On healthy playback with preflight failure -> watch + constrained
        final healthySummary = createSummary(isPlaying: true);
        final healthyAdvice = VGStreamingPlaybackHealthAdvisor.evaluate(
          VGStreamingPlaybackHealthAdvisorRequest(
            current: healthySummary,
            preflightReport: failedPreflight,
          ),
        );
        expect(
          healthyAdvice.severity,
          equals(VGStreamingPlaybackHealthSeverity.watch),
        );
        expect(
          healthyAdvice.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.preferConstrainedProfile),
        );
        expect(
          healthyAdvice.recommendedNetworkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(healthyAdvice.warnings, contains('bandwidth_too_low'));
        expect(healthyAdvice.reasons, contains('preflight_validation_failed'));

        // Terminal state still dominates
        final terminalSummary = createSummary(
          isTerminal: true,
          raw: 'state=disposed',
          diagnostics: {'state': 'disposed'},
        );
        final terminalAdvice = VGStreamingPlaybackHealthAdvisor.evaluate(
          VGStreamingPlaybackHealthAdvisorRequest(
            current: terminalSummary,
            preflightReport: failedPreflight,
          ),
        );
        expect(
          terminalAdvice.severity,
          equals(VGStreamingPlaybackHealthSeverity.terminal),
        );
        expect(
          terminalAdvice.recommendedAction,
          equals(VGStreamingPlaybackHealthAction.doNotRetryTerminal),
        );
      },
    );

    test('12. Empty summary without active session returns watch', () {
      const emptySummary = VGStreamingPlaybackStatusSummary.empty();
      final request = VGStreamingPlaybackHealthAdvisorRequest(
        current: emptySummary,
      );
      final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);

      expect(advice.severity, equals(VGStreamingPlaybackHealthSeverity.watch));
      expect(
        advice.recommendedAction,
        equals(VGStreamingPlaybackHealthAction.keepCurrentProfile),
      );
      expect(advice.shouldRetry, isFalse);
      expect(advice.reasons, contains('no_active_session'));
    });

    test('13. Custom thresholds are respected in evaluation', () {
      final summary = createSummary(
        isPlaying: true,
        bufferedPercent: 25,
        bufferedPositionMs: 3000,
      );
      // Under default threshold (15%), 25% is healthy
      final defaultAdvice = VGStreamingPlaybackHealthAdvisor.evaluate(
        VGStreamingPlaybackHealthAdvisorRequest(current: summary),
      );
      expect(
        defaultAdvice.severity,
        equals(VGStreamingPlaybackHealthSeverity.healthy),
      );

      // Under custom strict threshold (30%), 25% triggers watch
      final strictAdvice = VGStreamingPlaybackHealthAdvisor.evaluate(
        VGStreamingPlaybackHealthAdvisorRequest(
          current: summary,
          lowBufferPercentThreshold: 30,
        ),
      );
      expect(
        strictAdvice.severity,
        equals(VGStreamingPlaybackHealthSeverity.watch),
      );
      expect(
        strictAdvice.recommendedAction,
        equals(VGStreamingPlaybackHealthAction.waitForBuffer),
      );
    });

    test('14. Request and Advice serialization and toString work cleanly', () {
      final summary = createSummary();
      final request = VGStreamingPlaybackHealthAdvisorRequest(
        current: summary,
        currentNetworkProfile: VGStreamingNetworkProfile.auto,
      );
      final reqJson = request.toJson();
      expect(reqJson['currentNetworkProfile'], equals('AUTO'));
      expect(reqJson['recentCount'], equals(0));
      expect(
        request.toString(),
        contains('VGStreamingPlaybackHealthAdvisorRequest'),
      );

      final advice = VGStreamingPlaybackHealthAdvisor.evaluate(request);
      final adviceJson = advice.toJson();
      expect(adviceJson['severity'], equals('healthy'));
      expect(adviceJson['recommendedAction'], equals('keepCurrentProfile'));
      expect(adviceJson['advisoryOnly'], isTrue);
      expect(adviceJson['playbackMutation'], isFalse);
      expect(advice.toString(), contains('VGStreamingPlaybackHealthAdvice'));
    });
  });
}
