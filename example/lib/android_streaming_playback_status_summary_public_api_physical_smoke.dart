// Copyright (c) Connects — Vanguard Phase 4C7AB.
// Public streaming playback status summary -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Generation of preflight request directly from sourceSet under CONSTRAINED profile.
//   3. Preflight evaluation via VGStreamingPreflightClient.
//   4. Pure-Dart VGStreamingPlaybackDecisionPlanner planning.
//   5. Execution of adaptive streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   6. Querying controller snapshot, converting to VGStreamingPlaybackStatusSummary, and validating all status summary invariants:
//      - hasSession == true
//      - durationMs >= -1
//      - positionMs >= 0
//      - bufferedPositionMs >= 0
//      - bufferedPercent in 0..100
//      - progressFraction in 0.0..1.0
//      - bufferedFraction in 0.0..1.0
//      - effectiveDisplayWidth > 0
//      - effectiveDisplayHeight > 0
//      - summary can be serialized into JSON diagnostics
//   7. Lifecycle control (pause, seek, play, stop, dispose) and terminal state assertion.
//
// Verification Invariants & Boundaries:
// - Imports ONLY package:vanguard_media_engine/vanguard_media_engine.dart.
// - Does NOT import package:flutter/services.dart.
// - Does NOT construct raw MethodChannel.
// - Pure advisory preflight before playback; single active session per controller.
// - Bounded convenience verification only; does not make product feed decisions, ABR policy, or caching policy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingPlaybackStatusSummaryPhysicalSmokeApp());
}

class AndroidStreamingPlaybackStatusSummaryPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingPlaybackStatusSummaryPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingPlaybackStatusSummaryPhysicalSmokeApp> createState() =>
      _AndroidStreamingPlaybackStatusSummaryPhysicalSmokeAppState();
}

class _AndroidStreamingPlaybackStatusSummaryPhysicalSmokeAppState
    extends State<AndroidStreamingPlaybackStatusSummaryPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android streaming playback status summary physical smoke…';
  VGStreamingPlaybackControllerSnapshot _currentSnapshot =
      const VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.idle,
        pass: true,
        reason: 'idle',
      );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runStatusSummarySmoke();
    });
  }

  Future<void> _runStatusSummarySmoke() async {
    // Settle window for Flutter host
    await Future<void>.delayed(const Duration(seconds: 1));

    bool preflightPass = false;
    bool summaryPass = false;
    bool allPass = false;

    Map<String, dynamic> preflightDiag = <String, dynamic>{};
    Map<String, dynamic> summaryDiag = <String, dynamic>{};
    VGStreamingPlaybackController? controller;

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/3: Building source set and running preflight…';
        });
      }

      // Step 1: Define stable HLS streaming source
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'hls_smoke',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
            initialWidth: 1080,
            initialHeight: 1920,
          ),
        ],
      );

      final preflightRequest = sourceSet.toPreflightRequest(
        requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
      );

      final report = await _preflightClient.evaluate(preflightRequest);
      preflightDiag = Map<String, dynamic>.from(report.diagnostics);

      preflightPass =
          report.phase == 'Phase4C5G' &&
          report.pass == true &&
          report.totalReports == 1 &&
          report.failedReports == 0 &&
          report.advisoryOnly == true &&
          report.playbackMutation == false;

      if (!preflightPass) {
        throw Exception(
          'Preflight failed: pass=${report.pass}, phase=${report.phase}, '
          'failedReports=${report.failedReports}',
        );
      }

      if (mounted) {
        setState(() {
          _status =
              'Step 2/3: Planning playback decision and opening controller…';
        });
      }

      // Step 2: Build decision & open controller
      final decision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: report,
          preference: VGStreamingSourceSelectionPreference.preserveOrder,
        ),
      );

      if (!decision.canOpenPlayback || decision.decision != 'playback_ready') {
        throw Exception(
          'Decision planning failed: canOpenPlayback=${decision.canOpenPlayback}, '
          'decision=${decision.decision}',
        );
      }

      controller = VGStreamingPlaybackController();
      final openSnapshot = await controller.open(decision, startPlayback: true);

      if (!openSnapshot.pass || openSnapshot.textureId == null) {
        throw Exception(
          'Controller open failed: pass=${openSnapshot.pass}, '
          'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}',
        );
      }

      if (mounted) {
        setState(() {
          _currentSnapshot = openSnapshot;
          _status =
              'Step 3/3: Waiting for rendered frames and verifying status summary…';
        });
      }

      // Step 3: Poll controller until renderedFrames > 0 (timeout 12s)
      const maxWaitSeconds = 12;
      final stopwatch = Stopwatch()..start();
      VGStreamingPlaybackControllerSnapshot refreshSnapshot = openSnapshot;
      int renderedFrames = 0;

      while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        refreshSnapshot = await controller.refresh();
        renderedFrames = refreshSnapshot.session?.renderedFrames ?? 0;
        if (mounted) {
          setState(() {
            _currentSnapshot = refreshSnapshot;
          });
        }
        if (renderedFrames > 0) {
          break;
        }
      }

      if (renderedFrames <= 0) {
        throw Exception(
          'Timed out waiting for rendered frames (renderedFrames=0)',
        );
      }

      // Step 4: Construct status summary and verify all invariants
      final summary = VGStreamingPlaybackStatusSummary.fromControllerSnapshot(
        refreshSnapshot,
      );

      final hasSessionValid = summary.hasSession == true;
      final durationValid = summary.durationMs >= -1;
      final positionValid = summary.positionMs >= 0;
      final bufferedPosValid = summary.bufferedPositionMs >= 0;
      final bufferedPercentValid =
          summary.bufferedPercent >= 0 && summary.bufferedPercent <= 100;
      final progressFractionValid =
          summary.progressFraction >= 0.0 && summary.progressFraction <= 1.0;
      final bufferedFractionValid =
          summary.bufferedFraction >= 0.0 && summary.bufferedFraction <= 1.0;
      final widthValid = summary.effectiveDisplayWidth > 0;
      final heightValid = summary.effectiveDisplayHeight > 0;

      summaryDiag = summary.toJson();
      final jsonString = jsonEncode(summaryDiag);
      final jsonValid = jsonString.isNotEmpty;

      summaryPass =
          hasSessionValid &&
          durationValid &&
          positionValid &&
          bufferedPosValid &&
          bufferedPercentValid &&
          progressFractionValid &&
          bufferedFractionValid &&
          widthValid &&
          heightValid &&
          jsonValid;

      if (!summaryPass) {
        throw Exception(
          'Status summary invariant assertion failed: '
          'hasSession=$hasSessionValid, duration=$durationValid, position=$positionValid, '
          'bufferedPos=$bufferedPosValid, bufferedPercent=$bufferedPercentValid, '
          'progressFraction=$progressFractionValid, bufferedFraction=$bufferedFractionValid, '
          'width=$widthValid, height=$heightValid, json=$jsonValid',
        );
      }

      // Step 5: Test pause, play, stop, dispose lifecycle
      final pauseSnap = await controller.pause();
      if (!pauseSnap.pass) {
        throw Exception('Pause failed: reason=${pauseSnap.reason}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final playSnap = await controller.play();
      if (!playSnap.pass) {
        throw Exception('Play resume failed: reason=${playSnap.reason}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final stopSnap = await controller.stop();
      if (!stopSnap.pass) {
        throw Exception('Stop failed: reason=${stopSnap.reason}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final disposeSnap = await controller.dispose();
      if (!disposeSnap.pass ||
          disposeSnap.state != VGStreamingPlaybackControllerState.disposed) {
        throw Exception(
          'Dispose failed: state=${disposeSnap.state}, pass=${disposeSnap.pass}',
        );
      }

      // Summary on disposed controller snapshot
      final disposedSummary =
          VGStreamingPlaybackStatusSummary.fromControllerSnapshot(disposeSnap);
      final disposedSummaryValid =
          disposedSummary.isTerminal && !disposedSummary.isPlaying;

      if (!disposedSummaryValid) {
        throw Exception(
          'Disposed summary invariant failed: isTerminal=${disposedSummary.isTerminal}',
        );
      }

      allPass = preflightPass && summaryPass && disposedSummaryValid;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_PLAYBACK_STATUS_SUMMARY_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      allPass = false;
    } finally {
      if (controller != null && !controller.isDisposed) {
        try {
          await controller.dispose();
        } catch (_) {}
      }
    }

    final aggregatedMap = <String, dynamic>{
      'pass': allPass,
      'preflightPass': preflightPass,
      'summaryPass': summaryPass,
      'preflight': preflightDiag,
      'summary': summaryDiag,
    };

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_PLAYBACK_STATUS_SUMMARY_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_PLAYBACK_STATUS_SUMMARY_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_PLAYBACK_STATUS_SUMMARY_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Streaming Playback Status Summary Verified (Preflight: OK, Summary: OK, Dispose: OK)'
            : 'FAIL: Status Summary Smoke Failed';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(allPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 320,
                height: 180,
                child: VGStreamingPlaybackTextureView(
                  snapshot: _currentSnapshot,
                  fit: BoxFit.contain,
                  placeholderBuilder: (context, snap) {
                    return Container(
                      color: const Color(0xFF1E1E1E),
                      alignment: Alignment.center,
                      child: Text(
                        'No texture (${snap.state.name})',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
