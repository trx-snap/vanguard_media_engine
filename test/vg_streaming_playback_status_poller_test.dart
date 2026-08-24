// Copyright (c) Connects — Vanguard Phase 4C7AC.
// Public streaming playback status poller unit tests.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

class FakeStreamingPlaybackClient extends VGStreamingPlaybackClient {
  int openCalls = 0;
  int playCalls = 0;
  int getStatusCalls = 0;
  int disposeCalls = 0;

  VGStreamingPlaybackSession Function(VGStreamingPlaybackOptions options)?
  onOpen;
  VGStreamingPlaybackSession Function(VGStreamingPlaybackSession session)?
  onPlay;
  FutureOr<VGStreamingPlaybackSession> Function(
    VGStreamingPlaybackSession session,
  )?
  onGetStatus;
  Future<void> Function(VGStreamingPlaybackSession session)? onDispose;

  @override
  Future<VGStreamingPlaybackSession> open(
    VGStreamingPlaybackOptions options,
  ) async {
    openCalls++;
    if (onOpen != null) {
      return onOpen!(options);
    }
    return VGStreamingPlaybackSession(
      pass: true,
      phase: 'Phase4C1D1',
      sessionId: 'sess_poller_1',
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
      durationMs: session.durationMs > 0 ? session.durationMs : 60000,
      positionMs: session.positionMs >= 0 ? session.positionMs : 1000,
      bufferedPositionMs: session.bufferedPositionMs >= 0
          ? session.bufferedPositionMs
          : 5000,
      bufferedPercent: session.bufferedPercent > 0
          ? session.bufferedPercent
          : 10,
      videoWidth: 1920,
      videoHeight: 1080,
      raw: 'status=OK',
      diagnostics: {'play': 'success'},
    );
  }

  @override
  Future<VGStreamingPlaybackSession> getStatus(
    VGStreamingPlaybackSession session,
  ) async {
    getStatusCalls++;
    if (onGetStatus != null) {
      return await onGetStatus!(session);
    }
    return VGStreamingPlaybackSession(
      pass: true,
      phase: session.phase,
      sessionId: session.sessionId,
      textureId: session.textureId,
      format: session.format,
      state: VGStreamingPlaybackState.playing,
      durationMs: 60000,
      positionMs: 15000,
      bufferedPositionMs: 30000,
      bufferedPercent: 50,
      videoWidth: 1920,
      videoHeight: 1080,
      raw: 'status=OK',
      diagnostics: {'getStatus': 'success'},
    );
  }

  @override
  Future<void> dispose(VGStreamingPlaybackSession session) async {
    disposeCalls++;
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

  final validDecision = VGStreamingPlaybackDecisionPlanner.plan(
    VGStreamingPlaybackDecisionRequest(
      sourceSet: sourceSet,
      preflightReport: validPreflight,
    ),
  );

  group('VGStreamingPlaybackStatusPollerConfig', () {
    test('1. default configuration has expected values', () {
      final config = VGStreamingPlaybackStatusPollerConfig();
      expect(config.interval, equals(const Duration(milliseconds: 500)));
      expect(config.emitInitialSummary, isTrue);
      expect(config.toString(), contains('500ms'));
    });

    test('2. custom configuration preserves values', () {
      final config = VGStreamingPlaybackStatusPollerConfig(
        interval: const Duration(seconds: 2),
        emitInitialSummary: false,
      );
      expect(config.interval, equals(const Duration(seconds: 2)));
      expect(config.emitInitialSummary, isFalse);
    });

    test('3. config rejects zero/negative interval with ArgumentError', () {
      expect(
        () => VGStreamingPlaybackStatusPollerConfig(interval: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => VGStreamingPlaybackStatusPollerConfig(
          interval: const Duration(milliseconds: -100),
        ),
        throwsArgumentError,
      );
    });
  });

  group('VGStreamingPlaybackStatusPoller', () {
    late FakeStreamingPlaybackClient fakeClient;
    late VGStreamingPlaybackController controller;

    setUp(() {
      fakeClient = FakeStreamingPlaybackClient();
      controller = VGStreamingPlaybackController(playbackClient: fakeClient);
    });

    tearDown(() async {
      if (!controller.isDisposed) {
        await controller.dispose();
      }
    });

    test('1. initial poller state reflects controller snapshot', () {
      final poller = VGStreamingPlaybackStatusPoller(controller: controller);

      expect(poller.isRunning, isFalse);
      expect(poller.isDisposed, isFalse);
      expect(poller.latest.hasSession, isFalse);
      expect(poller.latest.isPlaying, isFalse);
      expect(poller.latest.durationMs, equals(-1));
      expect(poller.toString(), contains('isRunning=false'));
    });

    test(
      '2. refreshOnce() without active session emits and returns summary from snapshot',
      () async {
        final poller = VGStreamingPlaybackStatusPoller(controller: controller);

        final emittedSummaries = <VGStreamingPlaybackStatusSummary>[];
        final sub = poller.summaries.listen(emittedSummaries.add);

        final result = await poller.refreshOnce();

        expect(result.hasSession, isFalse);
        expect(result.isPlaying, isFalse);
        expect(poller.latest.hasSession, isFalse);
        expect(fakeClient.getStatusCalls, equals(0));

        await Future<void>.delayed(Duration.zero);
        expect(emittedSummaries.length, equals(1));
        expect(emittedSummaries.first.hasSession, isFalse);

        await sub.cancel();
        await poller.dispose();
      },
    );

    test(
      '3. refreshOnce() with active session queries controller and emits updated summary',
      () async {
        await controller.open(validDecision);
        final poller = VGStreamingPlaybackStatusPoller(controller: controller);

        final emittedSummaries = <VGStreamingPlaybackStatusSummary>[];
        final sub = poller.summaries.listen(emittedSummaries.add);

        final result = await poller.refreshOnce();

        expect(fakeClient.getStatusCalls, equals(1));
        expect(result.hasSession, isTrue);
        expect(result.isPlaying, isTrue);
        expect(result.durationMs, equals(60000));
        expect(result.positionMs, equals(15000));
        expect(result.bufferedPositionMs, equals(30000));
        expect(result.bufferedPercent, equals(50));
        expect(result.progressFraction, closeTo(0.25, 0.001));
        expect(result.bufferedFraction, closeTo(0.50, 0.001));

        await Future<void>.delayed(Duration.zero);
        expect(emittedSummaries.length, equals(1));
        expect(emittedSummaries.first.positionMs, equals(15000));

        await sub.cancel();
        await poller.dispose();
      },
    );

    test(
      '4. refreshOnce() catches exception on controller refresh and emits fallback safely',
      () async {
        await controller.open(validDecision);
        fakeClient.onGetStatus = (_) {
          throw Exception('network_timeout');
        };

        final poller = VGStreamingPlaybackStatusPoller(controller: controller);
        final emittedSummaries = <VGStreamingPlaybackStatusSummary>[];
        final sub = poller.summaries.listen(emittedSummaries.add);

        final result = await poller.refreshOnce();

        expect(result.hasSession, isTrue);
        expect(poller.latest.hasSession, isTrue);

        await Future<void>.delayed(Duration.zero);
        expect(emittedSummaries.length, equals(1));

        await sub.cancel();
        await poller.dispose();
      },
    );

    test('5. start() is idempotent and emits initial summary', () async {
      await controller.open(validDecision);
      final poller = VGStreamingPlaybackStatusPoller(
        controller: controller,
        config: VGStreamingPlaybackStatusPollerConfig(
          interval: const Duration(milliseconds: 100),
          emitInitialSummary: true,
        ),
      );

      final emittedSummaries = <VGStreamingPlaybackStatusSummary>[];
      final sub = poller.summaries.listen(emittedSummaries.add);

      poller.start();
      expect(poller.isRunning, isTrue);

      poller.start();
      expect(poller.isRunning, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(emittedSummaries.isNotEmpty, isTrue);
      expect(emittedSummaries.first.hasSession, isTrue);

      poller.stop();
      expect(poller.isRunning, isFalse);

      await sub.cancel();
      await poller.dispose();
    });

    test(
      '6. start() with emitInitialSummary=false does not emit immediately',
      () async {
        await controller.open(validDecision);
        final poller = VGStreamingPlaybackStatusPoller(
          controller: controller,
          config: VGStreamingPlaybackStatusPollerConfig(
            interval: const Duration(milliseconds: 200),
            emitInitialSummary: false,
          ),
        );

        final emittedSummaries = <VGStreamingPlaybackStatusSummary>[];
        final sub = poller.summaries.listen(emittedSummaries.add);

        poller.start();
        expect(poller.isRunning, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(emittedSummaries.isEmpty, isTrue);
        expect(fakeClient.getStatusCalls, equals(0));

        poller.stop();
        await sub.cancel();
        await poller.dispose();
      },
    );

    test(
      '7. overlapping refresh ticks do not call controller.refresh() concurrently',
      () async {
        await controller.open(validDecision);

        final completer = Completer<VGStreamingPlaybackSession>();
        fakeClient.onGetStatus = (_) => completer.future;

        final poller = VGStreamingPlaybackStatusPoller(controller: controller);

        final future1 = poller.refreshOnce();
        expect(fakeClient.getStatusCalls, equals(1));

        final future2 = poller.refreshOnce();
        expect(fakeClient.getStatusCalls, equals(1));

        completer.complete(
          const VGStreamingPlaybackSession(
            pass: true,
            phase: 'Phase4C1D1',
            sessionId: 'sess_poller_1',
            textureId: 101,
            format: VGStreamingFormatHint.hls,
            state: VGStreamingPlaybackState.playing,
            durationMs: 60000,
            positionMs: 20000,
            bufferedPositionMs: 40000,
            bufferedPercent: 66,
            raw: 'status=OK',
            diagnostics: {},
          ),
        );

        final summary1 = await future1;
        final summary2 = await future2;

        expect(summary1.positionMs, equals(20000));
        expect(summary2, isNotNull);
        expect(fakeClient.getStatusCalls, equals(1));

        await poller.dispose();
      },
    );

    test('8. stop() cancels periodic polling', () async {
      await controller.open(validDecision);
      final poller = VGStreamingPlaybackStatusPoller(
        controller: controller,
        config: VGStreamingPlaybackStatusPollerConfig(
          interval: const Duration(milliseconds: 50),
          emitInitialSummary: false,
        ),
      );

      poller.start();
      expect(poller.isRunning, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      final callsBeforeStop = fakeClient.getStatusCalls;
      expect(callsBeforeStop, greaterThanOrEqualTo(1));

      poller.stop();
      expect(poller.isRunning, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(fakeClient.getStatusCalls, equals(callsBeforeStop));

      await poller.dispose();
    });

    test(
      '9. dispose() is idempotent, closes stream, and does not dispose controller',
      () async {
        await controller.open(validDecision);
        final poller = VGStreamingPlaybackStatusPoller(
          controller: controller,
          config: VGStreamingPlaybackStatusPollerConfig(
            interval: const Duration(milliseconds: 50),
          ),
        );

        poller.start();
        expect(poller.isRunning, isTrue);

        bool streamDone = false;
        poller.summaries.listen(
          (_) {},
          onDone: () {
            streamDone = true;
          },
        );

        await poller.dispose();

        expect(poller.isDisposed, isTrue);
        expect(poller.isRunning, isFalse);
        expect(streamDone, isTrue);

        expect(controller.isDisposed, isFalse);
        expect(fakeClient.disposeCalls, equals(0));

        await poller.dispose();
        expect(poller.isDisposed, isTrue);
      },
    );

    test(
      '10. disposed refreshOnce() does not throw and returns latest',
      () async {
        final poller = VGStreamingPlaybackStatusPoller(controller: controller);
        await poller.dispose();

        expect(poller.isDisposed, isTrue);

        final summary = await poller.refreshOnce();
        expect(summary.hasSession, isFalse);

        poller.start();
        expect(poller.isRunning, isFalse);
        poller.stop();
        expect(poller.isRunning, isFalse);
      },
    );
  });
}
