// Copyright (c) Connects — Vanguard Phase 4C7AA.
// Public streaming playback status summary unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackStatusSummary', () {
    test('1. empty constructor returns safe default values', () {
      const summary = VGStreamingPlaybackStatusSummary.empty();

      expect(summary.hasSession, isFalse);
      expect(summary.isLive, isFalse);
      expect(summary.isSeekable, isFalse);
      expect(summary.isPlaying, isFalse);
      expect(summary.isBufferingOrOpening, isFalse);
      expect(summary.isTerminal, isFalse);
      expect(summary.durationMs, equals(-1));
      expect(summary.positionMs, equals(0));
      expect(summary.bufferedPositionMs, equals(0));
      expect(summary.bufferedPercent, equals(0));
      expect(summary.liveOffsetMs, isNull);
      expect(summary.progressFraction, equals(0.0));
      expect(summary.bufferedFraction, equals(0.0));
      expect(summary.effectiveDisplayWidth, equals(0));
      expect(summary.effectiveDisplayHeight, equals(0));
      expect(summary.hasRotationMetadata, isFalse);
      expect(summary.playbackCacheEnabled, isFalse);
      expect(summary.playbackCacheTelemetryAttached, isFalse);
      expect(summary.playbackCacheReadObserved, isFalse);
      expect(summary.playbackCacheBytesRead, equals(0));
      expect(summary.playbackCacheSizeBytes, equals(0));
      expect(summary.playbackCacheIgnoredCount, equals(0));
      expect(summary.playbackCacheLastIgnoredReason, isNull);
      expect(summary.raw, equals('status=EMPTY'));
      expect(summary.diagnostics['hasSession'], isFalse);

      final json = summary.toJson();
      expect(json['hasSession'], isFalse);
      expect(json['progressFraction'], equals(0.0));
      expect(json['bufferedFraction'], equals(0.0));
    });

    test('2. fromSession with null session returns empty summary', () {
      final summary = VGStreamingPlaybackStatusSummary.fromSession(null);

      expect(summary.hasSession, isFalse);
      expect(summary.durationMs, equals(-1));
      expect(summary.positionMs, equals(0));
      expect(summary.bufferedPercent, equals(0));
      expect(summary.progressFraction, equals(0.0));
      expect(summary.bufferedFraction, equals(0.0));
    });

    test('3. VOD progress and buffer fractions calculation', () {
      const session = VGStreamingPlaybackSession(
        pass: true,
        phase: 'Phase4C1D1',
        sessionId: 'vod_sess_1',
        textureId: 10,
        format: VGStreamingFormatHint.hls,
        state: VGStreamingPlaybackState.playing,
        durationMs: 60000,
        positionMs: 15000,
        bufferedPositionMs: 30000,
        bufferedPercent: 50,
        liveOffsetMs: null,
        videoWidth: 1920,
        videoHeight: 1080,
        rotationDegrees: 0,
        raw: 'status=OK',
        diagnostics: {'test': 'vod'},
      );

      final summary = VGStreamingPlaybackStatusSummary.fromSession(session);

      expect(summary.hasSession, isTrue);
      expect(summary.isLive, isFalse);
      expect(summary.isSeekable, isTrue);
      expect(summary.isPlaying, isTrue);
      expect(summary.isBufferingOrOpening, isFalse);
      expect(summary.isTerminal, isFalse);
      expect(summary.durationMs, equals(60000));
      expect(summary.positionMs, equals(15000));
      expect(summary.bufferedPositionMs, equals(30000));
      expect(summary.bufferedPercent, equals(50));
      expect(summary.liveOffsetMs, isNull);
      expect(summary.progressFraction, closeTo(0.25, 0.0001));
      expect(summary.bufferedFraction, closeTo(0.50, 0.0001));
      expect(summary.effectiveDisplayWidth, equals(1920));
      expect(summary.effectiveDisplayHeight, equals(1080));
      expect(summary.hasRotationMetadata, isFalse);
      expect(summary.raw, equals('status=OK'));
      expect(summary.diagnostics['test'], equals('vod'));
    });

    test('4. Live stream behavior (durationMs < 0 or liveOffsetMs != null)', () {
      // 4a. Live stream with durationMs = -1 and liveOffsetMs = 2500
      const liveSession1 = VGStreamingPlaybackSession(
        pass: true,
        phase: 'Phase4C1D1',
        sessionId: 'live_sess_1',
        textureId: 11,
        format: VGStreamingFormatHint.hls,
        state: VGStreamingPlaybackState.playing,
        durationMs: -1,
        positionMs: 45000,
        bufferedPositionMs: 48000,
        bufferedPercent: 80,
        liveOffsetMs: 2500,
        videoWidth: 1280,
        videoHeight: 720,
        raw: 'status=OK',
        diagnostics: {},
      );

      final summary1 = VGStreamingPlaybackStatusSummary.fromSession(
        liveSession1,
      );

      expect(summary1.hasSession, isTrue);
      expect(summary1.isLive, isTrue);
      expect(summary1.isSeekable, isFalse);
      expect(summary1.durationMs, equals(-1));
      expect(summary1.positionMs, equals(45000));
      expect(summary1.liveOffsetMs, equals(2500));
      expect(summary1.progressFraction, equals(0.0));
      expect(summary1.bufferedFraction, closeTo(0.80, 0.0001));

      // 4b. Live stream with positive durationMs (window) but liveOffsetMs != null
      const liveSession2 = VGStreamingPlaybackSession(
        pass: true,
        phase: 'Phase4C1D1',
        sessionId: 'live_sess_2',
        textureId: 12,
        format: VGStreamingFormatHint.hls,
        state: VGStreamingPlaybackState.buffering,
        durationMs: 30000,
        positionMs: 28000,
        bufferedPositionMs: 29000,
        bufferedPercent: 60,
        liveOffsetMs: 1200,
        videoWidth: 1080,
        videoHeight: 1920,
        raw: 'status=OK',
        diagnostics: {},
      );

      final summary2 = VGStreamingPlaybackStatusSummary.fromSession(
        liveSession2,
      );

      expect(summary2.isLive, isTrue);
      expect(summary2.isSeekable, isFalse);
      expect(summary2.progressFraction, equals(0.0));
      expect(summary2.bufferedFraction, closeTo(0.60, 0.0001));
      expect(summary2.isBufferingOrOpening, isTrue);
    });

    test('5. Lifecycle and terminal state mapping from session', () {
      // Opening
      final openingSummary = VGStreamingPlaybackStatusSummary.fromSession(
        const VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 's',
          textureId: 1,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.opening,
          raw: 'status=OK',
          diagnostics: {},
        ),
      );
      expect(openingSummary.isBufferingOrOpening, isTrue);
      expect(openingSummary.isPlaying, isFalse);
      expect(openingSummary.isTerminal, isFalse);

      // Buffering
      final bufferingSummary = VGStreamingPlaybackStatusSummary.fromSession(
        const VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 's',
          textureId: 1,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.buffering,
          raw: 'status=OK',
          diagnostics: {},
        ),
      );
      expect(bufferingSummary.isBufferingOrOpening, isTrue);
      expect(bufferingSummary.isPlaying, isFalse);
      expect(bufferingSummary.isTerminal, isFalse);

      // Seeking
      final seekingSummary = VGStreamingPlaybackStatusSummary.fromSession(
        const VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 's',
          textureId: 1,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.seeking,
          raw: 'status=OK',
          diagnostics: {},
        ),
      );
      expect(seekingSummary.isBufferingOrOpening, isTrue);
      expect(seekingSummary.isPlaying, isFalse);
      expect(seekingSummary.isTerminal, isFalse);

      // Ended
      final endedSummary = VGStreamingPlaybackStatusSummary.fromSession(
        const VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 's',
          textureId: 1,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.ended,
          raw: 'status=OK',
          diagnostics: {},
        ),
      );
      expect(endedSummary.isTerminal, isTrue);
      expect(endedSummary.isPlaying, isFalse);

      // Failed
      final failedSummary = VGStreamingPlaybackStatusSummary.fromSession(
        const VGStreamingPlaybackSession(
          pass: false,
          phase: 'Phase4C1D1',
          sessionId: 's',
          textureId: 1,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.failed,
          raw: 'status=FAIL',
          diagnostics: {},
        ),
      );
      expect(failedSummary.isTerminal, isTrue);

      // Disposed
      final disposedSummary = VGStreamingPlaybackStatusSummary.fromSession(
        const VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 's',
          textureId: 1,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.disposed,
          raw: 'status=DISPOSED',
          diagnostics: {},
        ),
      );
      expect(disposedSummary.isTerminal, isTrue);

      // Unsupported
      final unsupportedSummary = VGStreamingPlaybackStatusSummary.fromSession(
        VGStreamingPlaybackSession.unsupported(),
      );
      expect(unsupportedSummary.isTerminal, isTrue);
    });

    test('6. Controller snapshot mapping with and without active session', () {
      // 6a. Snapshot without session in idle state
      const idleSnapshot = VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.idle,
        pass: true,
        reason: 'idle',
      );
      final idleSummary =
          VGStreamingPlaybackStatusSummary.fromControllerSnapshot(idleSnapshot);

      expect(idleSummary.hasSession, isFalse);
      expect(idleSummary.isPlaying, isFalse);
      expect(idleSummary.isBufferingOrOpening, isFalse);
      expect(idleSummary.isTerminal, isFalse);
      expect(idleSummary.raw, equals('idle'));

      // 6b. Snapshot without session in opening state
      const openingSnapshot = VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.opening,
        pass: true,
        reason: 'opening',
      );
      final openingSummary =
          VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
            openingSnapshot,
          );

      expect(openingSummary.hasSession, isFalse);
      expect(openingSummary.isBufferingOrOpening, isTrue);
      expect(openingSummary.isPlaying, isFalse);
      expect(openingSummary.isTerminal, isFalse);

      // 6c. Snapshot without session in stopped / disposed / failed / unsupported state
      const stoppedSnapshot = VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.stopped,
        pass: true,
        reason: 'stopped',
      );
      expect(
        VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
          stoppedSnapshot,
        ).isTerminal,
        isTrue,
      );

      const disposedSnapshot = VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.disposed,
        pass: true,
        reason: 'disposed',
      );
      expect(
        VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
          disposedSnapshot,
        ).isTerminal,
        isTrue,
      );

      const failedSnapshot = VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.failed,
        pass: false,
        reason: 'failed',
      );
      expect(
        VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
          failedSnapshot,
        ).isTerminal,
        isTrue,
      );

      // 6d. Snapshot with active playing session
      const activeSession = VGStreamingPlaybackSession(
        pass: true,
        phase: 'Phase4C1D1',
        sessionId: 'snap_sess_1',
        textureId: 42,
        format: VGStreamingFormatHint.hls,
        state: VGStreamingPlaybackState.playing,
        durationMs: 100000,
        positionMs: 25000,
        bufferedPositionMs: 50000,
        bufferedPercent: 50,
        videoWidth: 1080,
        videoHeight: 1920,
        rotationDegrees: 90,
        raw: 'status=OK',
        diagnostics: {'controller': 'active'},
      );

      const playingSnapshot = VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.playing,
        session: activeSession,
        pass: true,
        reason: 'playing',
        diagnostics: {'snapshot_diag': true},
      );

      final playingSummary =
          VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
            playingSnapshot,
          );

      expect(playingSummary.hasSession, isTrue);
      expect(playingSummary.isPlaying, isTrue);
      expect(playingSummary.isBufferingOrOpening, isFalse);
      expect(playingSummary.isTerminal, isFalse);
      expect(playingSummary.progressFraction, closeTo(0.25, 0.0001));
      expect(playingSummary.bufferedFraction, closeTo(0.50, 0.0001));
      expect(
        playingSummary.effectiveDisplayWidth,
        equals(1920),
      ); // swapped for 90 deg
      expect(playingSummary.effectiveDisplayHeight, equals(1080));
      expect(playingSummary.hasRotationMetadata, isTrue);
      expect(playingSummary.diagnostics['snapshot_diag'], isTrue);
    });

    test('7. Cache read observed and cache telemetry propagation', () {
      const cacheSession = VGStreamingPlaybackSession(
        pass: true,
        phase: 'Phase4C1D1',
        sessionId: 'cache_sess',
        textureId: 77,
        format: VGStreamingFormatHint.hls,
        state: VGStreamingPlaybackState.playing,
        durationMs: 40000,
        positionMs: 10000,
        bufferedPositionMs: 20000,
        bufferedPercent: 50,
        playbackCacheEnabled: true,
        playbackCacheTelemetryAttached: true,
        playbackCacheBytesRead: 1048576, // 1MB
        playbackCacheSizeBytes: 2097152, // 2MB
        playbackCacheIgnoredCount: 2,
        playbackCacheLastIgnoredReason: 'cache_bypass_live',
        raw: 'status=OK',
        diagnostics: {},
      );

      final summary = VGStreamingPlaybackStatusSummary.fromSession(
        cacheSession,
      );

      expect(summary.playbackCacheEnabled, isTrue);
      expect(summary.playbackCacheTelemetryAttached, isTrue);
      expect(summary.playbackCacheReadObserved, isTrue);
      expect(summary.playbackCacheBytesRead, equals(1048576));
      expect(summary.playbackCacheSizeBytes, equals(2097152));
      expect(summary.playbackCacheIgnoredCount, equals(2));
      expect(
        summary.playbackCacheLastIgnoredReason,
        equals('cache_bypass_live'),
      );

      final json = summary.toJson();
      expect(json['playbackCacheEnabled'], isTrue);
      expect(json['playbackCacheTelemetryAttached'], isTrue);
      expect(json['playbackCacheReadObserved'], isTrue);
      expect(json['playbackCacheBytesRead'], equals(1048576));
      expect(json['playbackCacheSizeBytes'], equals(2097152));
      expect(json['playbackCacheIgnoredCount'], equals(2));
      expect(
        json['playbackCacheLastIgnoredReason'],
        equals('cache_bypass_live'),
      );
    });

    test('8. Defensive clamping of out-of-range telemetry', () {
      // Test negative and overflow values
      const dirtySession = VGStreamingPlaybackSession(
        pass: true,
        phase: 'Phase4C1D1',
        sessionId: 'dirty_sess',
        textureId: 99,
        format: VGStreamingFormatHint.hls,
        state: VGStreamingPlaybackState.playing,
        durationMs: 1000,
        positionMs: -500, // negative position
        bufferedPositionMs: -200, // negative buffered position
        bufferedPercent: 150, // overflow > 100
        playbackCacheBytesRead: -10, // negative cache bytes
        playbackCacheSizeBytes: -20, // negative cache size
        playbackCacheIgnoredCount: -5, // negative ignored count
        raw: 'status=DIRTY',
        diagnostics: {},
      );

      final summary = VGStreamingPlaybackStatusSummary.fromSession(
        dirtySession,
      );

      expect(summary.positionMs, equals(0));
      expect(summary.bufferedPositionMs, equals(0));
      expect(summary.bufferedPercent, equals(100)); // clamped to 100
      expect(summary.progressFraction, equals(0.0));
      expect(summary.bufferedFraction, equals(1.0));
      expect(summary.playbackCacheBytesRead, equals(0));
      expect(summary.playbackCacheSizeBytes, equals(0));
      expect(summary.playbackCacheIgnoredCount, equals(0));
      expect(summary.playbackCacheReadObserved, isFalse);

      // Position exceeding duration clamps progressFraction to 1.0
      const overflowPositionSession = VGStreamingPlaybackSession(
        pass: true,
        phase: 'Phase4C1D1',
        sessionId: 'overflow_pos',
        textureId: 100,
        format: VGStreamingFormatHint.hls,
        state: VGStreamingPlaybackState.playing,
        durationMs: 5000,
        positionMs: 10000, // exceeds duration
        bufferedPositionMs: 5000,
        bufferedPercent: 100,
        raw: 'status=OK',
        diagnostics: {},
      );

      final overflowSummary = VGStreamingPlaybackStatusSummary.fromSession(
        overflowPositionSession,
      );
      expect(overflowSummary.progressFraction, equals(1.0));
    });

    test('9. toString produces informative human-readable string', () {
      const summary = VGStreamingPlaybackStatusSummary.empty();
      final str = summary.toString();

      expect(str, contains('VGStreamingPlaybackStatusSummary'));
      expect(str, contains('hasSession=false'));
      expect(str, contains('isLive=false'));
      expect(str, contains('progressFraction=0.000'));
    });
  });
}
