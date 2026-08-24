// Copyright (c) Connects — Vanguard Phase 4C7O.
// Public streaming playback controller unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

class FakeStreamingPlaybackClient extends VGStreamingPlaybackClient {
  int openCalls = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  int seekCalls = 0;
  int stopCalls = 0;
  int getStatusCalls = 0;
  int disposeCalls = 0;

  VGStreamingPlaybackOptions? lastOpenedOptions;
  int? lastSeekPositionMs;
  VGStreamingPlaybackSession? lastDisposedSession;

  VGStreamingPlaybackSession Function(VGStreamingPlaybackOptions options)?
  onOpen;
  VGStreamingPlaybackSession Function(VGStreamingPlaybackSession session)?
  onPlay;
  VGStreamingPlaybackSession Function(VGStreamingPlaybackSession session)?
  onPause;
  VGStreamingPlaybackSession Function(
    VGStreamingPlaybackSession session,
    int positionMs,
  )?
  onSeek;
  VGStreamingPlaybackSession Function(VGStreamingPlaybackSession session)?
  onStop;
  VGStreamingPlaybackSession Function(VGStreamingPlaybackSession session)?
  onGetStatus;
  Future<void> Function(VGStreamingPlaybackSession session)? onDispose;

  @override
  Future<VGStreamingPlaybackSession> open(
    VGStreamingPlaybackOptions options,
  ) async {
    openCalls++;
    lastOpenedOptions = options;
    if (onOpen != null) {
      return onOpen!(options);
    }
    return VGStreamingPlaybackSession(
      pass: true,
      phase: 'Phase4C1D1',
      sessionId: 'sess_101',
      textureId: 101,
      format: options.formatHint,
      state: VGStreamingPlaybackState.opening,
      raw: 'status=OK',
      diagnostics: {'open': 'success'},
    );
  }

  @override
  Future<VGStreamingPlaybackSession> play(
    VGStreamingPlaybackSession session,
  ) async {
    playCalls++;
    if (onPlay != null) {
      return onPlay!(session);
    }
    return VGStreamingPlaybackSession(
      pass: true,
      phase: session.phase,
      sessionId: session.sessionId,
      textureId: session.textureId,
      format: session.format,
      state: VGStreamingPlaybackState.playing,
      durationMs: session.durationMs,
      positionMs: session.positionMs,
      bufferedPositionMs: session.bufferedPositionMs,
      bufferedPercent: session.bufferedPercent,
      liveOffsetMs: session.liveOffsetMs,
      videoWidth: session.videoWidth,
      videoHeight: session.videoHeight,
      rotationDegrees: session.rotationDegrees,
      displayWidth: session.displayWidth,
      displayHeight: session.displayHeight,
      renderedFrames: 1,
      raw: 'status=OK',
      diagnostics: {'play': 'success'},
    );
  }

  @override
  Future<VGStreamingPlaybackSession> pause(
    VGStreamingPlaybackSession session,
  ) async {
    pauseCalls++;
    if (onPause != null) {
      return onPause!(session);
    }
    return VGStreamingPlaybackSession(
      pass: true,
      phase: session.phase,
      sessionId: session.sessionId,
      textureId: session.textureId,
      format: session.format,
      state: VGStreamingPlaybackState.paused,
      durationMs: session.durationMs,
      positionMs: session.positionMs,
      bufferedPositionMs: session.bufferedPositionMs,
      bufferedPercent: session.bufferedPercent,
      liveOffsetMs: session.liveOffsetMs,
      videoWidth: session.videoWidth,
      videoHeight: session.videoHeight,
      rotationDegrees: session.rotationDegrees,
      displayWidth: session.displayWidth,
      displayHeight: session.displayHeight,
      renderedFrames: session.renderedFrames,
      raw: 'status=OK',
      diagnostics: {'pause': 'success'},
    );
  }

  @override
  Future<VGStreamingPlaybackSession> seek(
    VGStreamingPlaybackSession session,
    int positionMs,
  ) async {
    seekCalls++;
    lastSeekPositionMs = positionMs;
    if (onSeek != null) {
      return onSeek!(session, positionMs);
    }
    return VGStreamingPlaybackSession(
      pass: true,
      phase: session.phase,
      sessionId: session.sessionId,
      textureId: session.textureId,
      format: session.format,
      state: VGStreamingPlaybackState.seeking,
      durationMs: session.durationMs,
      positionMs: positionMs,
      bufferedPositionMs: session.bufferedPositionMs,
      bufferedPercent: session.bufferedPercent,
      liveOffsetMs: session.liveOffsetMs,
      videoWidth: session.videoWidth,
      videoHeight: session.videoHeight,
      rotationDegrees: session.rotationDegrees,
      displayWidth: session.displayWidth,
      displayHeight: session.displayHeight,
      renderedFrames: session.renderedFrames,
      raw: 'status=OK',
      diagnostics: {'seek': 'success'},
    );
  }

  @override
  Future<VGStreamingPlaybackSession> stop(
    VGStreamingPlaybackSession session,
  ) async {
    stopCalls++;
    if (onStop != null) {
      return onStop!(session);
    }
    return VGStreamingPlaybackSession(
      pass: true,
      phase: session.phase,
      sessionId: session.sessionId,
      textureId: session.textureId,
      format: session.format,
      state: VGStreamingPlaybackState.idle,
      durationMs: session.durationMs,
      positionMs: session.positionMs,
      bufferedPositionMs: session.bufferedPositionMs,
      bufferedPercent: session.bufferedPercent,
      liveOffsetMs: session.liveOffsetMs,
      videoWidth: session.videoWidth,
      videoHeight: session.videoHeight,
      rotationDegrees: session.rotationDegrees,
      displayWidth: session.displayWidth,
      displayHeight: session.displayHeight,
      renderedFrames: session.renderedFrames,
      raw: 'status=OK',
      diagnostics: {'stop': 'success'},
    );
  }

  @override
  Future<VGStreamingPlaybackSession> getStatus(
    VGStreamingPlaybackSession session,
  ) async {
    getStatusCalls++;
    if (onGetStatus != null) {
      return onGetStatus!(session);
    }
    return VGStreamingPlaybackSession(
      pass: true,
      phase: session.phase,
      sessionId: session.sessionId,
      textureId: session.textureId,
      format: session.format,
      state: session.state,
      durationMs: session.durationMs,
      positionMs: session.positionMs,
      bufferedPositionMs: session.bufferedPositionMs,
      bufferedPercent: session.bufferedPercent,
      liveOffsetMs: session.liveOffsetMs,
      videoWidth: session.videoWidth,
      videoHeight: session.videoHeight,
      rotationDegrees: session.rotationDegrees,
      displayWidth: session.displayWidth,
      displayHeight: session.displayHeight,
      renderedFrames: 10,
      raw: 'status=OK',
      diagnostics: {'refresh': 'success'},
    );
  }

  @override
  Future<void> dispose(VGStreamingPlaybackSession session) async {
    disposeCalls++;
    lastDisposedSession = session;
    if (onDispose != null) {
      await onDispose!(session);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final hlsSource = VGStreamingSourceDescriptor(
    key: 'hls_test',
    uri: Uri.parse('https://example.com/test.m3u8'),
    initialWidth: 1920,
    initialHeight: 1080,
    formatHint: VGStreamingFormatHint.hls,
  );

  final sourceSet = VGStreamingSourceSet(sources: [hlsSource]);

  const validPreflight = VGStreamingPreflightReport(
    pass: true,
    phase: 'Phase4C5G',
    advisoryDecision: 'preflight_passed',
    requestedNetworkProfile: 'STABLE',
    recommendedNetworkProfile: 'STABLE',
    recommendedNetworkPolicy: <String, Object?>{},
    totalReports: 1,
    passedReports: 1,
    failedReports: 0,
    warnings: <String>[],
    deviceWarnings: <String>[],
    llHlsAvailable: true,
    advisoryOnly: true,
    playbackMutation: false,
    serverLadderPolicy: '',
    iosMirrorNote: '',
    raw: 'status=OK',
    diagnostics: <String, Object?>{},
  );

  const blockedPreflight = VGStreamingPreflightReport(
    pass: false,
    phase: 'Phase4C5G',
    advisoryDecision: 'blocked_manifest_unreachable',
    requestedNetworkProfile: 'STABLE',
    recommendedNetworkProfile: 'CONSTRAINED',
    recommendedNetworkPolicy: <String, Object?>{},
    totalReports: 1,
    passedReports: 0,
    failedReports: 1,
    warnings: <String>['network_unreachable'],
    deviceWarnings: <String>[],
    llHlsAvailable: false,
    advisoryOnly: true,
    playbackMutation: false,
    serverLadderPolicy: '',
    iosMirrorNote: '',
    raw: 'status=ERROR',
    diagnostics: <String, Object?>{},
  );

  final validDecision = VGStreamingPlaybackDecisionPlanner.plan(
    VGStreamingPlaybackDecisionRequest(
      sourceSet: sourceSet,
      preflightReport: validPreflight,
    ),
  );

  final blockedDecision = VGStreamingPlaybackDecisionPlanner.plan(
    VGStreamingPlaybackDecisionRequest(
      sourceSet: sourceSet,
      preflightReport: blockedPreflight,
    ),
  );

  group('VGStreamingPlaybackController', () {
    // 1. Initial snapshot
    test('1. initial snapshot has state idle, pass true, and no session', () {
      final client = FakeStreamingPlaybackClient();
      final controller = VGStreamingPlaybackController(playbackClient: client);

      expect(
        controller.snapshot.state,
        equals(VGStreamingPlaybackControllerState.idle),
      );
      expect(controller.snapshot.pass, isTrue);
      expect(controller.snapshot.reason, equals('idle'));
      expect(controller.snapshot.session, isNull);
      expect(controller.snapshot.textureId, isNull);
      expect(controller.snapshot.decision, isNull);
      expect(controller.snapshot.lastError, isNull);
      expect(controller.snapshot.diagnostics, isEmpty);
      expect(controller.snapshot.durationMs, equals(-1));
      expect(controller.snapshot.positionMs, equals(0));
      expect(controller.snapshot.bufferedPositionMs, equals(0));
      expect(controller.snapshot.bufferedPercent, equals(0));
      expect(controller.snapshot.liveOffsetMs, isNull);
      expect(controller.snapshot.hasPlaybackTelemetry, isFalse);
      expect(controller.isDisposed, isFalse);
    });

    // 2. Blocked decision does not call open
    test(
      '2. blocked decision does not call open and moves to failed',
      () async {
        final client = FakeStreamingPlaybackClient();
        final controller = VGStreamingPlaybackController(
          playbackClient: client,
        );

        final snapshot = await controller.open(blockedDecision);

        expect(client.openCalls, equals(0));
        expect(
          snapshot.state,
          equals(VGStreamingPlaybackControllerState.failed),
        );
        expect(snapshot.pass, isFalse);
        expect(snapshot.reason, equals('decision_blocked'));
        expect(snapshot.session, isNull);
        expect(snapshot.textureId, isNull);
        expect(snapshot.decision, equals(blockedDecision));
        expect(snapshot.diagnostics['canOpenPlayback'], isFalse);
      },
    );

    // 3. Successful open with startPlayback calls open then play and exposes textureId
    test(
      '3. successful open with startPlayback calls open then play and exposes textureId',
      () async {
        final client = FakeStreamingPlaybackClient();
        final controller = VGStreamingPlaybackController(
          playbackClient: client,
        );

        final snapshot = await controller.open(
          validDecision,
          startPlayback: true,
        );

        expect(client.openCalls, equals(1));
        expect(client.playCalls, equals(1));
        expect(
          snapshot.state,
          equals(VGStreamingPlaybackControllerState.playing),
        );
        expect(snapshot.pass, isTrue);
        expect(snapshot.reason, equals('playing'));
        expect(snapshot.session, isNotNull);
        expect(snapshot.session!.textureId, equals(101));
        expect(snapshot.textureId, equals(101));
        expect(snapshot.decision, equals(validDecision));
        expect(controller.snapshot.textureId, equals(101));
      },
    );

    // 4. Open with startPlayback false retains session without play
    test(
      '4. open with startPlayback false retains session without play',
      () async {
        final client = FakeStreamingPlaybackClient();
        client.onOpen = (options) => const VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_102',
          textureId: 102,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.paused,
          raw: 'status=OK',
          diagnostics: {},
        );

        final controller = VGStreamingPlaybackController(
          playbackClient: client,
        );
        final snapshot = await controller.open(
          validDecision,
          startPlayback: false,
        );

        expect(client.openCalls, equals(1));
        expect(client.playCalls, equals(0));
        expect(
          snapshot.state,
          equals(VGStreamingPlaybackControllerState.paused),
        );
        expect(snapshot.pass, isTrue);
        expect(snapshot.reason, equals('opened'));
        expect(snapshot.textureId, equals(102));
      },
    );

    // 5. Second open while active returns session_already_active and does not open again
    test(
      '5. second open while active returns session_already_active and does not open again',
      () async {
        final client = FakeStreamingPlaybackClient();
        final controller = VGStreamingPlaybackController(
          playbackClient: client,
        );

        await controller.open(validDecision, startPlayback: true);
        expect(client.openCalls, equals(1));

        final secondSnapshot = await controller.open(validDecision);

        expect(client.openCalls, equals(1));
        expect(secondSnapshot.pass, isFalse);
        expect(secondSnapshot.reason, equals('session_already_active'));
        expect(
          secondSnapshot.state,
          equals(VGStreamingPlaybackControllerState.playing),
        );
        expect(secondSnapshot.textureId, equals(101));
      },
    );

    // 6. play/pause/seek/refresh/stop sequence calls expected client methods and maps state
    test(
      '6. play/pause/seek/refresh/stop sequence calls expected client methods and maps state',
      () async {
        final client = FakeStreamingPlaybackClient();
        final controller = VGStreamingPlaybackController(
          playbackClient: client,
        );

        // Open in paused mode
        client.onOpen = (options) => const VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_103',
          textureId: 103,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.paused,
          raw: 'status=OK',
          diagnostics: {},
        );
        final openSnap = await controller.open(
          validDecision,
          startPlayback: false,
        );
        expect(
          openSnap.state,
          equals(VGStreamingPlaybackControllerState.paused),
        );

        // Play
        final playSnap = await controller.play();
        expect(client.playCalls, equals(1));
        expect(
          playSnap.state,
          equals(VGStreamingPlaybackControllerState.playing),
        );
        expect(playSnap.pass, isTrue);

        // Pause
        final pauseSnap = await controller.pause();
        expect(client.pauseCalls, equals(1));
        expect(
          pauseSnap.state,
          equals(VGStreamingPlaybackControllerState.paused),
        );
        expect(pauseSnap.pass, isTrue);

        // Seek
        final seekSnap = await controller.seek(3500);
        expect(client.seekCalls, equals(1));
        expect(client.lastSeekPositionMs, equals(3500));
        expect(
          seekSnap.state,
          equals(VGStreamingPlaybackControllerState.opening),
        ); // seeking maps to opening
        expect(seekSnap.pass, isTrue);

        // Refresh
        final refreshSnap = await controller.refresh();
        expect(client.getStatusCalls, equals(1));
        expect(refreshSnap.pass, isTrue);
        expect(refreshSnap.session?.renderedFrames, equals(10));

        // Stop
        final stopSnap = await controller.stop();
        expect(client.stopCalls, equals(1));
        expect(
          stopSnap.state,
          equals(VGStreamingPlaybackControllerState.stopped),
        );
        expect(stopSnap.pass, isTrue);
        expect(stopSnap.reason, equals('stopped'));
      },
    );

    // 7. Negative seek returns position_invalid without native call
    test(
      '7. negative seek returns position_invalid without native call',
      () async {
        final client = FakeStreamingPlaybackClient();
        final controller = VGStreamingPlaybackController(
          playbackClient: client,
        );

        await controller.open(validDecision, startPlayback: true);
        final snapshot = await controller.seek(-500);

        expect(client.seekCalls, equals(0));
        expect(snapshot.pass, isFalse);
        expect(snapshot.reason, equals('position_invalid'));
        expect(
          snapshot.state,
          equals(VGStreamingPlaybackControllerState.playing),
        );
      },
    );

    // 8. Dispose calls client dispose once and is idempotent
    test('8. dispose calls client dispose once and is idempotent', () async {
      final client = FakeStreamingPlaybackClient();
      final controller = VGStreamingPlaybackController(playbackClient: client);

      await controller.open(validDecision, startPlayback: true);
      expect(controller.snapshot.textureId, equals(101));

      final disposeSnap1 = await controller.dispose();
      expect(client.disposeCalls, equals(1));
      expect(client.lastDisposedSession?.textureId, equals(101));
      expect(
        disposeSnap1.state,
        equals(VGStreamingPlaybackControllerState.disposed),
      );
      expect(disposeSnap1.pass, isTrue);
      expect(disposeSnap1.session, isNull);
      expect(disposeSnap1.textureId, isNull);
      expect(controller.isDisposed, isTrue);

      // Second dispose call is a no-op
      final disposeSnap2 = await controller.dispose();
      expect(client.disposeCalls, equals(1));
      expect(
        disposeSnap2.state,
        equals(VGStreamingPlaybackControllerState.disposed),
      );

      // Operations after dispose return controller_disposed
      final playSnap = await controller.play();
      expect(playSnap.pass, isFalse);
      expect(playSnap.reason, equals('controller_disposed'));
      expect(
        playSnap.state,
        equals(VGStreamingPlaybackControllerState.disposed),
      );
    });

    // 9. Play failure after open triggers best-effort dispose of opened session and clears active session
    test(
      '9. play failure after open triggers best-effort dispose of opened session and clears active session',
      () async {
        final client = FakeStreamingPlaybackClient();
        client.onPlay = (session) => throw StateError('Play exploded');

        final controller = VGStreamingPlaybackController(
          playbackClient: client,
        );
        final snapshot = await controller.open(
          validDecision,
          startPlayback: true,
        );

        expect(client.openCalls, equals(1));
        expect(client.playCalls, equals(1));
        expect(client.disposeCalls, equals(1));
        expect(client.lastDisposedSession?.textureId, equals(101));
        expect(
          snapshot.state,
          equals(VGStreamingPlaybackControllerState.failed),
        );
        expect(snapshot.pass, isFalse);
        expect(snapshot.reason, equals('play_failed'));
        expect(snapshot.lastError, contains('Play exploded'));
        expect(snapshot.session, isNull);
        expect(snapshot.textureId, isNull);
      },
    );

    // 10. Unsupported open maps to unsupported
    test('10. unsupported open maps to unsupported', () async {
      final client = FakeStreamingPlaybackClient();
      client.onOpen = (options) => VGStreamingPlaybackSession.unsupported();

      final controller = VGStreamingPlaybackController(playbackClient: client);
      final snapshot = await controller.open(
        validDecision,
        startPlayback: true,
      );

      expect(client.openCalls, equals(1));
      expect(client.playCalls, equals(0));
      expect(
        snapshot.state,
        equals(VGStreamingPlaybackControllerState.unsupported),
      );
      expect(snapshot.pass, isFalse);
      expect(snapshot.reason, equals('open_failed'));
      expect(
        snapshot.session?.state,
        equals(VGStreamingPlaybackState.unsupported),
      );
      expect(snapshot.textureId, isNull);
    });

    // Additional coverage: methods without active session
    test('methods without active session return no_active_session', () async {
      final client = FakeStreamingPlaybackClient();
      final controller = VGStreamingPlaybackController(playbackClient: client);

      final playSnap = await controller.play();
      expect(playSnap.pass, isFalse);
      expect(playSnap.reason, equals('no_active_session'));

      final pauseSnap = await controller.pause();
      expect(pauseSnap.pass, isFalse);
      expect(pauseSnap.reason, equals('no_active_session'));

      final seekSnap = await controller.seek(100);
      expect(seekSnap.pass, isFalse);
      expect(seekSnap.reason, equals('no_active_session'));

      final refreshSnap = await controller.refresh();
      expect(refreshSnap.pass, isFalse);
      expect(refreshSnap.reason, equals('no_active_session'));

      // stop when no session returns already_stopped
      final stopSnap = await controller.stop();
      expect(stopSnap.pass, isTrue);
      expect(stopSnap.reason, equals('already_stopped'));
      expect(
        stopSnap.state,
        equals(VGStreamingPlaybackControllerState.stopped),
      );
    });

    // Additional coverage: reopen after stop disposes old session and opens new one
    test('reopen after stop disposes previous session and succeeds', () async {
      final client = FakeStreamingPlaybackClient();
      final controller = VGStreamingPlaybackController(playbackClient: client);

      await controller.open(validDecision, startPlayback: true);
      expect(client.openCalls, equals(1));

      await controller.stop();
      expect(
        controller.snapshot.state,
        equals(VGStreamingPlaybackControllerState.stopped),
      );

      // Now open a second time after stopping
      final secondOpen = await controller.open(validDecision);
      expect(
        client.disposeCalls,
        equals(1),
      ); // disposed the old stopped session
      expect(client.openCalls, equals(2));
      expect(secondOpen.pass, isTrue);
      expect(
        secondOpen.state,
        equals(VGStreamingPlaybackControllerState.playing),
      );
    });

    // Additional coverage: exception in dispose returns dispose_failed but leaves state disposed
    test(
      'exception in dispose sets pass false and reason dispose_failed but is disposed',
      () async {
        final client = FakeStreamingPlaybackClient();
        client.onDispose = (session) =>
            throw Exception('Native dispose crashed');

        final controller = VGStreamingPlaybackController(
          playbackClient: client,
        );
        await controller.open(validDecision, startPlayback: true);

        final disposeSnap = await controller.dispose();
        expect(
          disposeSnap.state,
          equals(VGStreamingPlaybackControllerState.disposed),
        );
        expect(disposeSnap.pass, isFalse);
        expect(disposeSnap.reason, equals('dispose_failed'));
        expect(disposeSnap.lastError, contains('Native dispose crashed'));
        expect(controller.isDisposed, isTrue);
      },
    );

    // 11. Snapshot convenience getters mirror active session telemetry and update on refresh
    test(
      '11. snapshot convenience getters mirror active session telemetry and update on refresh',
      () async {
        final client = FakeStreamingPlaybackClient();
        client.onOpen = (options) => const VGStreamingPlaybackSession(
          pass: true,
          phase: 'Phase4C1D1',
          sessionId: 'sess_111',
          textureId: 111,
          format: VGStreamingFormatHint.hls,
          state: VGStreamingPlaybackState.playing,
          durationMs: 120000,
          positionMs: 15000,
          bufferedPositionMs: 30000,
          bufferedPercent: 25,
          liveOffsetMs: 1200,
          raw: 'status=OK',
          diagnostics: {'telemetry': 'active'},
        );

        final controller = VGStreamingPlaybackController(
          playbackClient: client,
        );

        // Before open: safe defaults
        expect(controller.snapshot.durationMs, equals(-1));
        expect(controller.snapshot.positionMs, equals(0));
        expect(controller.snapshot.bufferedPositionMs, equals(0));
        expect(controller.snapshot.bufferedPercent, equals(0));
        expect(controller.snapshot.liveOffsetMs, isNull);
        expect(controller.snapshot.playbackCacheEnabled, isFalse);
        expect(controller.snapshot.playbackCacheTelemetryAttached, isFalse);
        expect(controller.snapshot.playbackCacheBytesRead, equals(0));
        expect(controller.snapshot.playbackCacheSizeBytes, equals(0));
        expect(controller.snapshot.playbackCacheIgnoredCount, equals(0));
        expect(controller.snapshot.playbackCacheLastIgnoredReason, isNull);
        expect(controller.snapshot.hasPlaybackTelemetry, isFalse);

        // Open
        final openSnapshot = await controller.open(
          validDecision,
          startPlayback: true,
        );
        expect(openSnapshot.durationMs, equals(120000));
        expect(openSnapshot.positionMs, equals(15000));
        expect(openSnapshot.bufferedPositionMs, equals(30000));
        expect(openSnapshot.bufferedPercent, equals(25));
        expect(openSnapshot.liveOffsetMs, equals(1200));
        expect(openSnapshot.hasPlaybackTelemetry, isTrue);
        expect(controller.snapshot.durationMs, equals(120000));
        expect(controller.snapshot.positionMs, equals(15000));
        expect(controller.snapshot.bufferedPositionMs, equals(30000));
        expect(controller.snapshot.bufferedPercent, equals(25));
        expect(controller.snapshot.liveOffsetMs, equals(1200));
        expect(controller.snapshot.hasPlaybackTelemetry, isTrue);

        // Update getStatus mock
        client.onGetStatus = (session) => VGStreamingPlaybackSession(
          pass: true,
          phase: session.phase,
          sessionId: session.sessionId,
          textureId: session.textureId,
          format: session.format,
          state: session.state,
          durationMs: 120000,
          positionMs: 45000,
          bufferedPositionMs: 60000,
          bufferedPercent: 50,
          liveOffsetMs: 800,
          renderedFrames: 120,
          playbackCacheEnabled: true,
          playbackCacheTelemetryAttached: true,
          playbackCacheBytesRead: 16384,
          playbackCacheSizeBytes: 32768,
          playbackCacheIgnoredCount: 1,
          playbackCacheLastIgnoredReason: 'unset_length',
          raw: 'status=OK',
          diagnostics: {'refresh': 'success'},
        );

        // Refresh updates snapshot-level telemetry
        final refreshSnapshot = await controller.refresh();
        expect(refreshSnapshot.durationMs, equals(120000));
        expect(refreshSnapshot.positionMs, equals(45000));
        expect(refreshSnapshot.bufferedPositionMs, equals(60000));
        expect(refreshSnapshot.bufferedPercent, equals(50));
        expect(refreshSnapshot.liveOffsetMs, equals(800));
        expect(refreshSnapshot.playbackCacheEnabled, isTrue);
        expect(refreshSnapshot.playbackCacheTelemetryAttached, isTrue);
        expect(refreshSnapshot.playbackCacheBytesRead, equals(16384));
        expect(refreshSnapshot.playbackCacheSizeBytes, equals(32768));
        expect(refreshSnapshot.playbackCacheIgnoredCount, equals(1));
        expect(
          refreshSnapshot.playbackCacheLastIgnoredReason,
          equals('unset_length'),
        );
        expect(refreshSnapshot.hasPlaybackTelemetry, isTrue);
        expect(controller.snapshot.positionMs, equals(45000));
        expect(controller.snapshot.bufferedPositionMs, equals(60000));
        expect(controller.snapshot.bufferedPercent, equals(50));
        expect(controller.snapshot.liveOffsetMs, equals(800));
        expect(controller.snapshot.playbackCacheEnabled, isTrue);
        expect(controller.snapshot.playbackCacheBytesRead, equals(16384));
        expect(controller.snapshot.playbackCacheSizeBytes, equals(32768));

        // Dispose clears session and reverts snapshot getters to safe defaults
        final disposeSnapshot = await controller.dispose();
        expect(disposeSnapshot.durationMs, equals(-1));
        expect(disposeSnapshot.positionMs, equals(0));
        expect(disposeSnapshot.bufferedPositionMs, equals(0));
        expect(disposeSnapshot.bufferedPercent, equals(0));
        expect(disposeSnapshot.liveOffsetMs, isNull);
        expect(disposeSnapshot.playbackCacheEnabled, isFalse);
        expect(disposeSnapshot.playbackCacheTelemetryAttached, isFalse);
        expect(disposeSnapshot.playbackCacheBytesRead, equals(0));
        expect(disposeSnapshot.playbackCacheSizeBytes, equals(0));
        expect(disposeSnapshot.playbackCacheIgnoredCount, equals(0));
        expect(disposeSnapshot.playbackCacheLastIgnoredReason, isNull);
        expect(disposeSnapshot.hasPlaybackTelemetry, isFalse);
        expect(controller.snapshot.durationMs, equals(-1));
        expect(controller.snapshot.positionMs, equals(0));
        expect(controller.snapshot.playbackCacheEnabled, isFalse);
        expect(controller.snapshot.playbackCacheBytesRead, equals(0));
        expect(controller.snapshot.hasPlaybackTelemetry, isFalse);
      },
    );
  });
}
