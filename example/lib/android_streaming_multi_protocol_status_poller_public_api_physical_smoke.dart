// Copyright (c) Connects — Vanguard Phase 4C7AG / Phase 4C7AH.
// Public multi-protocol streaming playback status poller -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate streams via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Generation of preflight request directly from sourceSet under CONSTRAINED profile.
//   3. Preflight evaluation via VGStreamingPreflightClient across HLS, DASH, and LL-HLS.
//   4. Pure-Dart VGStreamingPlaybackDecisionPlanner planning per protocol.
//   5. Execution of adaptive streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   6. Attaching VGStreamingPlaybackStatusPoller over VGStreamingPlaybackController for each protocol.
//   7. Starting the poller and collecting emitted summaries from broadcast Stream<VGStreamingPlaybackStatusSummary>.
//   8. Continuing polling until at least two summaries are collected AND real playback progress evidence
//      (renderedFrames > 0, isPlaying == true, positionMs > 0, or bufferedPositionMs > 0) is observed.
//   9. Asserting all status summary invariants across all 3 protocols:
//      - at least two emitted summaries collected
//      - at least one summary has hasSession == true
//      - durationMs >= -1
//      - positionMs >= 0
//      - bufferedPositionMs >= 0
//      - bufferedPercent in 0..100
//      - progressFraction in 0.0..1.0
//      - bufferedFraction in 0.0..1.0
//      - effectiveDisplayWidth > 0 and effectiveDisplayHeight > 0
//      - playback progress / render evidence observed (renderedFrames > 0, isPlaying == true, positionMs > 0, or bufferedPositionMs > 0)
//  10. Stopping and disposing poller cleanly without disposing underlying controller.
//  11. Verifying disposed poller refreshOnce() does not throw.
//  12. Stopping and disposing controller before proceeding to the next protocol.
//
// Verification Invariants & Boundaries:
// - Imports ONLY package:vanguard_media_engine/vanguard_media_engine.dart.
// - Does NOT import package:flutter/services.dart.
// - Does NOT construct raw MethodChannel.
// - Tests all three Android HTTP adaptive playback protocols (HLS, DASH, LL-HLS) sequentially with real playback progress evidence.
// - Bounded convenience verification only; does not make product feed decisions, ABR policy, or caching policy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingMultiProtocolStatusPollerPhysicalSmokeApp());
}

class AndroidStreamingMultiProtocolStatusPollerPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingMultiProtocolStatusPollerPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingMultiProtocolStatusPollerPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingMultiProtocolStatusPollerPhysicalSmokeAppState();
}

class _AndroidStreamingMultiProtocolStatusPollerPhysicalSmokeAppState
    extends State<AndroidStreamingMultiProtocolStatusPollerPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android multi-protocol streaming playback status poller physical smoke…';
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
      _runMultiProtocolStatusPollerSmoke();
    });
  }

  Future<void> _runMultiProtocolStatusPollerSmoke() async {
    // Settle window for Flutter host
    await Future<void>.delayed(const Duration(seconds: 1));

    bool preflightPass = false;
    bool allCasesPass = true;
    final caseResults = <String, dynamic>{};
    Map<String, dynamic> preflightDiag = <String, dynamic>{};

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/2: Building source set and running preflight…';
        });
      }

      // Step 1: Define candidate streams covering HLS, DASH, and LL-HLS
      final sourceSet = VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'hls',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
            initialWidth: 1080,
            initialHeight: 1920,
          ),
          VGStreamingSourceDescriptor(
            key: 'dash',
            uri: Uri.parse(
              'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
            ),
            formatHint: VGStreamingFormatHint.dash,
            initialWidth: 1080,
            initialHeight: 1920,
          ),
          VGStreamingSourceDescriptor(
            key: 'll_hls',
            uri: Uri.parse(
              'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
            ),
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
          report.totalReports == 3 &&
          report.failedReports == 0 &&
          report.advisoryOnly == true &&
          report.playbackMutation == false;

      if (!preflightPass) {
        throw Exception(
          'Preflight failed: pass=${report.pass}, phase=${report.phase}, '
          'total=${report.totalReports}, failed=${report.failedReports}',
        );
      }

      // Step 2: Sequentially evaluate status poller for each protocol
      final testCases = [
        (key: 'hls', label: 'HLS', preferredKeys: const ['hls']),
        (key: 'dash', label: 'DASH', preferredKeys: const ['dash']),
        (key: 'll_hls', label: 'LL-HLS', preferredKeys: const ['ll_hls']),
      ];

      for (int i = 0; i < testCases.length; i++) {
        final testCase = testCases[i];
        final stepIndex = i + 1;
        final totalSteps = testCases.length;

        if (mounted) {
          setState(() {
            _currentSnapshot = const VGStreamingPlaybackControllerSnapshot(
              state: VGStreamingPlaybackControllerState.idle,
              pass: true,
              reason: 'idle',
            );
            _status =
                'Case $stepIndex/$totalSteps: Planning & opening ${testCase.label} playback…';
          });
        }

        VGStreamingPlaybackController? controller;
        VGStreamingPlaybackStatusPoller? poller;
        StreamSubscription<VGStreamingPlaybackStatusSummary>? pollerSub;
        final collectedSummaries = <VGStreamingPlaybackStatusSummary>[];
        bool casePass = false;
        Map<String, dynamic> pollerDiag = <String, dynamic>{};
        int maxRenderedFrames = 0;
        int maxPositionMs = 0;
        int maxBufferedPositionMs = 0;
        bool sawPlaying = false;
        bool playbackProgressObserved = false;

        try {
          // 2a. Build decision & open controller
          final decision = VGStreamingPlaybackDecisionPlanner.plan(
            VGStreamingPlaybackDecisionRequest(
              sourceSet: sourceSet,
              preflightReport: report,
              preference: VGStreamingSourceSelectionPreference.preserveOrder,
              preferredKeys: testCase.preferredKeys,
            ),
          );

          if (!decision.canOpenPlayback ||
              decision.decision != 'playback_ready' ||
              decision.selectedKey != testCase.key) {
            throw Exception(
              'Decision planning failed for ${testCase.label}: canOpenPlayback=${decision.canOpenPlayback}, '
              'decision=${decision.decision}, selectedKey=${decision.selectedKey}',
            );
          }

          controller = VGStreamingPlaybackController();
          final openSnapshot = await controller.open(
            decision,
            startPlayback: true,
          );

          if (!openSnapshot.pass || openSnapshot.textureId == null) {
            throw Exception(
              'Controller open failed for ${testCase.label}: pass=${openSnapshot.pass}, '
              'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}',
            );
          }

          if (mounted) {
            setState(() {
              _currentSnapshot = openSnapshot;
              _status =
                  'Case $stepIndex/$totalSteps: Starting status poller for ${testCase.label}…';
            });
          }

          // 2b. Instantiate and start VGStreamingPlaybackStatusPoller
          poller = VGStreamingPlaybackStatusPoller(
            controller: controller,
            config: VGStreamingPlaybackStatusPollerConfig(
              interval: const Duration(milliseconds: 500),
              emitInitialSummary: true,
            ),
          );

          pollerSub = poller.summaries.listen((summary) {
            collectedSummaries.add(summary);
            if (summary.isPlaying) {
              sawPlaying = true;
            }
            if (summary.positionMs > maxPositionMs) {
              maxPositionMs = summary.positionMs;
            }
            if (summary.bufferedPositionMs > maxBufferedPositionMs) {
              maxBufferedPositionMs = summary.bufferedPositionMs;
            }
            if (mounted && controller != null) {
              final frames = controller!.snapshot.session?.renderedFrames ?? 0;
              if (frames > maxRenderedFrames) {
                maxRenderedFrames = frames;
              }
              setState(() {
                _currentSnapshot = controller!.snapshot;
              });
            }
          });

          poller.start();

          if (!poller.isRunning) {
            throw Exception(
              'Poller failed to start for ${testCase.label} (isRunning is false)',
            );
          }

          // 2c. Wait for at least 2 emitted summaries, valid display metrics, and real playback progress evidence (timeout 30s)
          const maxWaitSeconds = 30;
          final stopwatch = Stopwatch()..start();

          while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            final currentFrames =
                controller.snapshot.session?.renderedFrames ?? 0;
            if (currentFrames > maxRenderedFrames) {
              maxRenderedFrames = currentFrames;
            }
            final latest = poller.latest;
            if (latest.isPlaying) {
              sawPlaying = true;
            }
            if (latest.positionMs > maxPositionMs) {
              maxPositionMs = latest.positionMs;
            }
            if (latest.bufferedPositionMs > maxBufferedPositionMs) {
              maxBufferedPositionMs = latest.bufferedPositionMs;
            }

            playbackProgressObserved =
                maxRenderedFrames > 0 ||
                sawPlaying ||
                latest.isPlaying ||
                maxPositionMs > 0 ||
                latest.positionMs > 0 ||
                maxBufferedPositionMs > 0 ||
                latest.bufferedPositionMs > 0;

            if (collectedSummaries.length >= 2 &&
                latest.hasSession &&
                latest.effectiveDisplayWidth > 0 &&
                latest.effectiveDisplayHeight > 0 &&
                playbackProgressObserved) {
              // Prefer observing actual rendered frames when available
              if (maxRenderedFrames > 0 ||
                  stopwatch.elapsed >= const Duration(seconds: 6)) {
                break;
              }
            }
          }

          final currentFrames =
              controller.snapshot.session?.renderedFrames ?? 0;
          if (currentFrames > maxRenderedFrames) {
            maxRenderedFrames = currentFrames;
          }
          final latest = poller.latest;
          if (latest.isPlaying) {
            sawPlaying = true;
          }
          if (latest.positionMs > maxPositionMs) {
            maxPositionMs = latest.positionMs;
          }
          if (latest.bufferedPositionMs > maxBufferedPositionMs) {
            maxBufferedPositionMs = latest.bufferedPositionMs;
          }

          playbackProgressObserved =
              maxRenderedFrames > 0 ||
              sawPlaying ||
              latest.isPlaying ||
              maxPositionMs > 0 ||
              latest.positionMs > 0 ||
              maxBufferedPositionMs > 0 ||
              latest.bufferedPositionMs > 0;

          if (collectedSummaries.length < 2) {
            throw Exception(
              'Expected at least 2 emitted summaries for ${testCase.label}, but collected ${collectedSummaries.length}',
            );
          }

          if (!playbackProgressObserved) {
            throw Exception(
              'Playback progress evidence not observed for ${testCase.label}: '
              'maxRenderedFrames=$maxRenderedFrames, sawPlaying=$sawPlaying, '
              'maxPositionMs=$maxPositionMs, maxBufferedPositionMs=$maxBufferedPositionMs, '
              'latest=${latest.toJson()}',
            );
          }

          // 2d. Assert all status summary invariants
          bool hasActiveSessionSummary = false;
          bool hasDisplayDimensions = false;

          for (final summary in collectedSummaries) {
            if (summary.hasSession) {
              hasActiveSessionSummary = true;
            }
            if (summary.effectiveDisplayWidth > 0 &&
                summary.effectiveDisplayHeight > 0) {
              hasDisplayDimensions = true;
            }

            final durationValid = summary.durationMs >= -1;
            final positionValid = summary.positionMs >= 0;
            final bufferedPosValid = summary.bufferedPositionMs >= 0;
            final bufferedPercentValid =
                summary.bufferedPercent >= 0 && summary.bufferedPercent <= 100;
            final progressFractionValid =
                summary.progressFraction >= 0.0 &&
                summary.progressFraction <= 1.0;
            final bufferedFractionValid =
                summary.bufferedFraction >= 0.0 &&
                summary.bufferedFraction <= 1.0;

            if (!durationValid ||
                !positionValid ||
                !bufferedPosValid ||
                !bufferedPercentValid ||
                !progressFractionValid ||
                !bufferedFractionValid) {
              throw Exception(
                'Summary bounds violation for ${testCase.label}: duration=${summary.durationMs}, '
                'position=${summary.positionMs}, bufferedPos=${summary.bufferedPositionMs}, '
                'bufferedPercent=${summary.bufferedPercent}, progressFraction=${summary.progressFraction}, '
                'bufferedFraction=${summary.bufferedFraction}',
              );
            }
          }

          if (!hasActiveSessionSummary) {
            throw Exception(
              'None of the collected summaries for ${testCase.label} had hasSession=true',
            );
          }

          if (!hasDisplayDimensions) {
            throw Exception(
              'None of the collected summaries for ${testCase.label} had effectiveDisplayWidth > 0',
            );
          }

          pollerDiag = {
            'collectedCount': collectedSummaries.length,
            'hasActiveSession': hasActiveSessionSummary,
            'hasDisplayDimensions': hasDisplayDimensions,
            'playbackProgressObserved': playbackProgressObserved,
            'maxRenderedFrames': maxRenderedFrames,
            'maxPositionMs': maxPositionMs,
            'maxBufferedPositionMs': maxBufferedPositionMs,
            'sawPlaying': sawPlaying,
            'latest': poller.latest.toJson(),
          };

          if (mounted) {
            setState(() {
              _status =
                  'Case $stepIndex/$totalSteps: Testing poller stop, dispose & teardown for ${testCase.label}…';
            });
          }

          // 2e. Test poller stop & dispose
          poller.stop();
          if (poller.isRunning) {
            throw Exception(
              'Poller stop failed for ${testCase.label}: isRunning is still true',
            );
          }

          await pollerSub.cancel();
          pollerSub = null;

          await poller.dispose();
          if (!poller.isDisposed) {
            throw Exception(
              'Poller dispose failed for ${testCase.label}: isDisposed is false',
            );
          }

          // Controller should NOT be disposed by poller dispose
          if (controller.isDisposed) {
            throw Exception(
              'Poller dispose disposed the underlying controller for ${testCase.label}',
            );
          }

          // Disposed refreshOnce should not throw
          await poller.refreshOnce();

          // Stop & dispose controller
          await controller.stop();
          await controller.dispose();
          if (!controller.isDisposed) {
            throw Exception(
              'Controller dispose failed for ${testCase.label}: isDisposed is false',
            );
          }

          casePass =
              hasActiveSessionSummary &&
              hasDisplayDimensions &&
              collectedSummaries.length >= 2 &&
              playbackProgressObserved;
        } catch (error, stack) {
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_MULTI_PROTOCOL_STATUS_POLLER_PUBLIC_API_${testCase.key.toUpperCase()}_ERROR: $error\n$stack',
          );
          casePass = false;
        } finally {
          await pollerSub?.cancel();
          if (poller != null && !poller.isDisposed) {
            try {
              await poller.dispose();
            } catch (_) {}
          }
          if (controller != null && !controller.isDisposed) {
            try {
              await controller.dispose();
            } catch (_) {}
          }
        }

        if (!casePass) {
          allCasesPass = false;
        }

        caseResults[testCase.key] = <String, dynamic>{
          'protocol': testCase.label,
          'pass': casePass,
          'summariesCount': collectedSummaries.length,
          'playbackProgressObserved': playbackProgressObserved,
          'maxRenderedFrames': maxRenderedFrames,
          'maxPositionMs': maxPositionMs,
          'maxBufferedPositionMs': maxBufferedPositionMs,
          'sawPlaying': sawPlaying,
          'poller': pollerDiag,
        };

        if (mounted) {
          setState(() {
            _status =
                'Case $stepIndex/$totalSteps (${testCase.label}): ${casePass ? "PASS" : "FAIL"}';
          });
        }

        // Delay between test cases
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_MULTI_PROTOCOL_STATUS_POLLER_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      preflightPass = false;
      allCasesPass = false;
    }

    final allPass = preflightPass && allCasesPass;

    final aggregatedMap = <String, dynamic>{
      'pass': allPass,
      'preflightPass': preflightPass,
      'allCasesPass': allCasesPass,
      'hlsPass': caseResults['hls']?['pass'] == true,
      'dashPass': caseResults['dash']?['pass'] == true,
      'llHlsPass': caseResults['ll_hls']?['pass'] == true,
      'hlsSummariesCount': caseResults['hls']?['summariesCount'] ?? 0,
      'dashSummariesCount': caseResults['dash']?['summariesCount'] ?? 0,
      'llHlsSummariesCount': caseResults['ll_hls']?['summariesCount'] ?? 0,
      'hlsPlaybackProgressObserved':
          caseResults['hls']?['playbackProgressObserved'] == true,
      'dashPlaybackProgressObserved':
          caseResults['dash']?['playbackProgressObserved'] == true,
      'llHlsPlaybackProgressObserved':
          caseResults['ll_hls']?['playbackProgressObserved'] == true,
      'hlsMaxRenderedFrames': caseResults['hls']?['maxRenderedFrames'] ?? 0,
      'dashMaxRenderedFrames': caseResults['dash']?['maxRenderedFrames'] ?? 0,
      'llHlsMaxRenderedFrames':
          caseResults['ll_hls']?['maxRenderedFrames'] ?? 0,
      'hlsMaxPositionMs': caseResults['hls']?['maxPositionMs'] ?? 0,
      'dashMaxPositionMs': caseResults['dash']?['maxPositionMs'] ?? 0,
      'llHlsMaxPositionMs': caseResults['ll_hls']?['maxPositionMs'] ?? 0,
      'hlsMaxBufferedPositionMs':
          caseResults['hls']?['maxBufferedPositionMs'] ?? 0,
      'dashMaxBufferedPositionMs':
          caseResults['dash']?['maxBufferedPositionMs'] ?? 0,
      'llHlsMaxBufferedPositionMs':
          caseResults['ll_hls']?['maxBufferedPositionMs'] ?? 0,
      'hlsSawPlaying': caseResults['hls']?['sawPlaying'] == true,
      'dashSawPlaying': caseResults['dash']?['sawPlaying'] == true,
      'llHlsSawPlaying': caseResults['ll_hls']?['sawPlaying'] == true,
      'preflight': preflightDiag,
      'cases': caseResults,
    };

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_MULTI_PROTOCOL_STATUS_POLLER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_MULTI_PROTOCOL_STATUS_POLLER_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_MULTI_PROTOCOL_STATUS_POLLER_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Multi-Protocol Status Poller Verified (HLS: OK, DASH: OK, LL-HLS: OK)'
            : 'FAIL: Multi-Protocol Status Poller Smoke Failed';
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
