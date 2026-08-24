// Copyright (c) Connects — Vanguard Phase 4C7BA / Phase 4C7BB.
// Public multi-protocol streaming playback resilience coordinator -> physical playback smoke.
//
// Sequentially verifies across HLS, DASH, and LL-HLS:
//   1. Definition of candidate streams via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Generation of preflight request directly from sourceSet under CONSTRAINED profile.
//   3. Preflight evaluation via VGStreamingPreflightClient across HLS, DASH, and LL-HLS.
//   4. Pure-Dart VGStreamingPlaybackDecisionPlanner planning per protocol.
//   5. Execution of adaptive streaming playback via VGStreamingPlaybackController and presentation via VGStreamingPlaybackTextureView.
//   6. Starting VGStreamingPlaybackStatusPoller over VGStreamingPlaybackController.
//   7. Starting VGStreamingPlaybackResilienceMonitor over VGStreamingPlaybackStatusPoller.summaries.
//   8. Evaluating collected resilience snapshots through a fresh VGStreamingPlaybackResilienceCoordinator using the protocol stream key.
//   9. Asserting at least two monitor snapshots, hasSession == true, positive effective dimensions, and progress/render evidence (renderedFrames > 0 || isPlaying || positionMs > 0 || bufferedPositionMs > 0).
//  10. Asserting coordinator evaluation invariants:
//      - evaluation.advisoryOnly == true
//      - evaluation.playbackMutation == false
//      - evaluation.decision.advisoryOnly == true
//      - evaluation.decision.playbackMutation == false
//      - evaluation.retryBudget.advisoryOnly == true
//      - evaluation.retryBudget.playbackMutation == false
//      - evaluation.journalSnapshot.advisoryOnly == true
//      - evaluation.journalSnapshot.playbackMutation == false
//      - coordinator.length remains 0 after evaluate (pure advisory evaluate does not auto-record attempts)
//      - evaluation.action is a valid public VGStreamingPlaybackResilienceDecisionAction enum value
//      - evaluation diagnostics serialize to valid JSON
//  11. Stopping and disposing monitor cleanly without disposing underlying poller or controller.
//  12. Stopping and disposing poller cleanly without disposing underlying controller.
//  13. Stopping and disposing controller cleanly.
//  14. Verified non-claims: no real retry is executed and recordHostRetryAttempted() is not called in this smoke.
//
// Verification Invariants & Boundaries:
// - Imports ONLY dart:async, dart:convert, dart:io, package:flutter/material.dart, and package:vanguard_media_engine/vanguard_media_engine.dart.
// - Does NOT import package:flutter/services.dart.
// - Does NOT construct raw MethodChannel.
// - Tests all three Android HTTP adaptive playback protocols (HLS, DASH, LL-HLS) sequentially with real playback progress evidence.
// - Pure advisory evaluation wrapper; does not make product feed decisions, ABR policy, or caching policy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(
    const AndroidStreamingMultiProtocolResilienceCoordinatorPhysicalSmokeApp(),
  );
}

class AndroidStreamingMultiProtocolResilienceCoordinatorPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingMultiProtocolResilienceCoordinatorPhysicalSmokeApp({
    super.key,
  });

  @override
  State<AndroidStreamingMultiProtocolResilienceCoordinatorPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingMultiProtocolResilienceCoordinatorPhysicalSmokeAppState();
}

class _AndroidStreamingMultiProtocolResilienceCoordinatorPhysicalSmokeAppState
    extends
        State<
          AndroidStreamingMultiProtocolResilienceCoordinatorPhysicalSmokeApp
        > {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android multi-protocol streaming playback resilience coordinator physical smoke…';
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
      _runMultiProtocolResilienceCoordinatorSmoke();
    });
  }

  Future<void> _runMultiProtocolResilienceCoordinatorSmoke() async {
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

      // Step 2: Sequentially evaluate resilience coordinator for each protocol
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
        VGStreamingPlaybackResilienceMonitor? monitor;
        VGStreamingPlaybackResilienceCoordinator? coordinator;
        StreamSubscription<VGStreamingPlaybackResilienceSnapshot>? monitorSub;
        final collectedSnapshots = <VGStreamingPlaybackResilienceSnapshot>[];
        bool casePass = false;
        Map<String, dynamic> coordinatorEvalDiag = <String, dynamic>{};
        Map<String, dynamic> latestStatusDiag = <String, dynamic>{};
        int maxRenderedFrames = 0;
        int maxPositionMs = 0;
        int maxBufferedPositionMs = 0;
        bool sawPlaying = false;
        bool playbackProgressObserved = false;

        bool monitorDisposedPollerAlive = false;
        bool monitorDisposedControllerAlive = false;
        bool pollerDisposedControllerAlive = false;

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
                  'Case $stepIndex/$totalSteps: Setting up poller, monitor & coordinator for ${testCase.label}…';
            });
          }

          // 2b. Instantiate poller, resilience monitor & coordinator
          poller = VGStreamingPlaybackStatusPoller(
            controller: controller,
            config: VGStreamingPlaybackStatusPollerConfig(
              interval: const Duration(milliseconds: 500),
              emitInitialSummary: true,
            ),
          );

          monitor = VGStreamingPlaybackResilienceMonitor(
            summaries: poller.summaries,
            config: VGStreamingPlaybackResilienceMonitorConfig(
              currentOptions: decision.playbackOptions,
              preflightReport: report,
              currentNetworkProfile: VGStreamingNetworkProfile.constrained,
              maxHistoryLength: 8,
              allowAutomaticRetry: false,
            ),
          );

          coordinator = VGStreamingPlaybackResilienceCoordinator(
            config: VGStreamingPlaybackResilienceCoordinatorConfig(
              journalConfig: const VGStreamingPlaybackRetryJournalConfig(
                maxStoredAttempts: 10,
              ),
              retryBudgetConfig: const VGStreamingPlaybackRetryBudgetConfig(
                maxAttempts: 3,
                windowMs: 30000,
                minimumDelayMs: 1000,
              ),
              streamKey: testCase.key,
            ),
          );

          monitorSub = monitor.snapshots.listen((snapshot) {
            collectedSnapshots.add(snapshot);
            if (snapshot.status.isPlaying) {
              sawPlaying = true;
            }
            if (snapshot.status.positionMs > maxPositionMs) {
              maxPositionMs = snapshot.status.positionMs;
            }
            if (snapshot.status.bufferedPositionMs > maxBufferedPositionMs) {
              maxBufferedPositionMs = snapshot.status.bufferedPositionMs;
            }
            if (mounted && controller != null) {
              final frames = controller.snapshot.session?.renderedFrames ?? 0;
              if (frames > maxRenderedFrames) {
                maxRenderedFrames = frames;
              }
              setState(() {
                _currentSnapshot = controller!.snapshot;
              });
            }
          });

          // Start monitor, then poller
          monitor.start();
          poller.start();

          if (!monitor.isRunning) {
            throw Exception(
              'Resilience monitor failed to start for ${testCase.label} (isRunning is false)',
            );
          }
          if (!poller.isRunning) {
            throw Exception(
              'Status poller failed to start for ${testCase.label} (isRunning is false)',
            );
          }

          // 2c. Wait for at least 2 emitted resilience snapshots, valid display metrics, and real playback progress evidence (timeout 30s)
          const maxWaitSeconds = 30;
          final stopwatch = Stopwatch()..start();

          while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            final currentFrames =
                controller.snapshot.session?.renderedFrames ?? 0;
            if (currentFrames > maxRenderedFrames) {
              maxRenderedFrames = currentFrames;
            }
            final latestSnap = monitor.latest;
            if (latestSnap != null) {
              if (latestSnap.status.isPlaying) {
                sawPlaying = true;
              }
              if (latestSnap.status.positionMs > maxPositionMs) {
                maxPositionMs = latestSnap.status.positionMs;
              }
              if (latestSnap.status.bufferedPositionMs >
                  maxBufferedPositionMs) {
                maxBufferedPositionMs = latestSnap.status.bufferedPositionMs;
              }
            }

            playbackProgressObserved =
                maxRenderedFrames > 0 ||
                sawPlaying ||
                (latestSnap?.status.isPlaying ?? false) ||
                maxPositionMs > 0 ||
                (latestSnap?.status.positionMs ?? 0) > 0 ||
                maxBufferedPositionMs > 0 ||
                (latestSnap?.status.bufferedPositionMs ?? 0) > 0;

            if (collectedSnapshots.length >= 2 &&
                latestSnap != null &&
                latestSnap.status.hasSession &&
                latestSnap.status.effectiveDisplayWidth > 0 &&
                latestSnap.status.effectiveDisplayHeight > 0 &&
                playbackProgressObserved) {
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
          final latestSnap = monitor.latest;
          if (latestSnap != null) {
            if (latestSnap.status.isPlaying) {
              sawPlaying = true;
            }
            if (latestSnap.status.positionMs > maxPositionMs) {
              maxPositionMs = latestSnap.status.positionMs;
            }
            if (latestSnap.status.bufferedPositionMs > maxBufferedPositionMs) {
              maxBufferedPositionMs = latestSnap.status.bufferedPositionMs;
            }
          }

          playbackProgressObserved =
              maxRenderedFrames > 0 ||
              sawPlaying ||
              (latestSnap?.status.isPlaying ?? false) ||
              maxPositionMs > 0 ||
              (latestSnap?.status.positionMs ?? 0) > 0 ||
              maxBufferedPositionMs > 0 ||
              (latestSnap?.status.bufferedPositionMs ?? 0) > 0;

          if (collectedSnapshots.length < 2) {
            throw Exception(
              'Expected at least 2 emitted snapshots for ${testCase.label}, but collected ${collectedSnapshots.length}',
            );
          }

          if (latestSnap == null) {
            throw Exception(
              'Monitor latest snapshot is null after collection for ${testCase.label}',
            );
          }

          if (!latestSnap.status.hasSession) {
            throw Exception(
              'Latest snapshot status hasSession is false for ${testCase.label}',
            );
          }

          if (latestSnap.status.effectiveDisplayWidth <= 0 ||
              latestSnap.status.effectiveDisplayHeight <= 0) {
            throw Exception(
              'Latest snapshot effective dimensions non-positive for ${testCase.label}: '
              '${latestSnap.status.effectiveDisplayWidth}x${latestSnap.status.effectiveDisplayHeight}',
            );
          }

          if (!playbackProgressObserved) {
            throw Exception(
              'Playback progress evidence not observed for ${testCase.label}: '
              'maxRenderedFrames=$maxRenderedFrames, sawPlaying=$sawPlaying, '
              'maxPositionMs=$maxPositionMs, maxBufferedPositionMs=$maxBufferedPositionMs, '
              'latest=${latestSnap.status.toJson()}',
            );
          }

          // 2d. Evaluate collected snapshots through coordinator and assert coordinator invariants
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          VGStreamingPlaybackResilienceCoordinatorEvaluation? latestEvaluation;

          for (int s = 0; s < collectedSnapshots.length; s++) {
            final snap = collectedSnapshots[s];
            final eval = coordinator.evaluate(
              snapshot: snap,
              nowMs: nowMs + (s * 500),
              streamKey: testCase.key,
            );

            if (!eval.advisoryOnly || eval.playbackMutation) {
              throw Exception(
                'Coordinator evaluation advisory/mutation invariant violation for ${testCase.label}: '
                'advisoryOnly=${eval.advisoryOnly}, playbackMutation=${eval.playbackMutation}',
              );
            }
            if (!eval.decision.advisoryOnly || eval.decision.playbackMutation) {
              throw Exception(
                'Coordinator decision advisory/mutation invariant violation for ${testCase.label}: '
                'advisoryOnly=${eval.decision.advisoryOnly}, playbackMutation=${eval.decision.playbackMutation}',
              );
            }
            if (!eval.retryBudget.advisoryOnly ||
                eval.retryBudget.playbackMutation) {
              throw Exception(
                'Coordinator retryBudget advisory/mutation invariant violation for ${testCase.label}: '
                'advisoryOnly=${eval.retryBudget.advisoryOnly}, playbackMutation=${eval.retryBudget.playbackMutation}',
              );
            }
            if (!eval.journalSnapshot.advisoryOnly ||
                eval.journalSnapshot.playbackMutation) {
              throw Exception(
                'Coordinator journalSnapshot advisory/mutation invariant violation for ${testCase.label}: '
                'advisoryOnly=${eval.journalSnapshot.advisoryOnly}, playbackMutation=${eval.journalSnapshot.playbackMutation}',
              );
            }

            // Coordinator length must remain 0 (pure advisory evaluate does not auto-record attempts)
            if (coordinator.length != 0) {
              throw Exception(
                'Coordinator length was modified during evaluate for ${testCase.label}: length=${coordinator.length}',
              );
            }

            // Action must be a valid public enum value
            if (!VGStreamingPlaybackResilienceDecisionAction.values.contains(
              eval.action,
            )) {
              throw Exception(
                'Invalid coordinator action for ${testCase.label}: ${eval.action}',
              );
            }

            // Verify JSON serialization roundtrip
            final evalJson = eval.toJson();
            if (evalJson['advisoryOnly'] != true ||
                evalJson['playbackMutation'] != false) {
              throw Exception(
                'Coordinator evaluation JSON serialization invariant violated for ${testCase.label}',
              );
            }

            latestEvaluation = eval;
          }

          if (latestEvaluation == null) {
            throw Exception(
              'Failed to produce coordinator evaluation for ${testCase.label}',
            );
          }

          coordinatorEvalDiag = {
            'action': latestEvaluation.action.name,
            'canRetryNow': latestEvaluation.canRetryNow,
            'shouldRecordAttemptOnHostRetry':
                latestEvaluation.shouldRecordAttemptOnHostRetry,
            'requiresHostAction': latestEvaluation.requiresHostAction,
            'retryAfterMs': latestEvaluation.retryAfterMs,
            'reasons': latestEvaluation.reasons,
            'attemptsInWindow': latestEvaluation.retryBudget.attemptsInWindow,
            'remainingAttempts': latestEvaluation.retryBudget.remainingAttempts,
            'journalCount': latestEvaluation.journalSnapshot.count,
            'coordinatorLength': coordinator.length,
            'advisoryOnly': latestEvaluation.advisoryOnly,
            'playbackMutation': latestEvaluation.playbackMutation,
            'diagnostics': latestEvaluation.diagnostics,
          };

          latestStatusDiag = {
            'hasSession': latestSnap.status.hasSession,
            'isPlaying': latestSnap.status.isPlaying,
            'positionMs': latestSnap.status.positionMs,
            'bufferedPositionMs': latestSnap.status.bufferedPositionMs,
            'bufferedPercent': latestSnap.status.bufferedPercent,
            'effectiveDisplayWidth': latestSnap.status.effectiveDisplayWidth,
            'effectiveDisplayHeight': latestSnap.status.effectiveDisplayHeight,
            'renderedFrames': controller.snapshot.session?.renderedFrames,
          };

          if (mounted) {
            setState(() {
              _status =
                  'Case $stepIndex/$totalSteps: Testing monitor/poller teardown for ${testCase.label}…';
            });
          }

          // 2e. Test monitor stop & dispose without disposing poller or controller
          monitor.stop();
          if (monitor.isRunning) {
            throw Exception(
              'Monitor stop failed for ${testCase.label}: isRunning is still true',
            );
          }

          await monitorSub.cancel();
          monitorSub = null;

          await monitor.dispose();
          if (!monitor.isDisposed) {
            throw Exception(
              'Monitor dispose failed for ${testCase.label}: isDisposed is false',
            );
          }

          monitorDisposedPollerAlive = !poller.isDisposed;
          monitorDisposedControllerAlive = !controller.isDisposed;

          if (!monitorDisposedPollerAlive) {
            throw Exception(
              'Monitor disposal disposed underlying poller for ${testCase.label}',
            );
          }
          if (!monitorDisposedControllerAlive) {
            throw Exception(
              'Monitor disposal disposed underlying controller for ${testCase.label}',
            );
          }

          // Stop & dispose poller without disposing controller
          poller.stop();
          if (poller.isRunning) {
            throw Exception(
              'Poller stop failed for ${testCase.label}: isRunning is still true',
            );
          }

          await poller.dispose();
          if (!poller.isDisposed) {
            throw Exception(
              'Poller dispose failed for ${testCase.label}: isDisposed is false',
            );
          }

          pollerDisposedControllerAlive = !controller.isDisposed;
          if (!pollerDisposedControllerAlive) {
            throw Exception(
              'Poller disposal disposed underlying controller for ${testCase.label}',
            );
          }

          // Stop & dispose controller
          await controller.stop();
          await controller.dispose();
          if (!controller.isDisposed) {
            throw Exception(
              'Controller dispose failed for ${testCase.label}: isDisposed is false',
            );
          }

          casePass =
              collectedSnapshots.length >= 2 &&
              latestSnap.status.hasSession &&
              latestSnap.status.effectiveDisplayWidth > 0 &&
              latestSnap.status.effectiveDisplayHeight > 0 &&
              playbackProgressObserved &&
              latestEvaluation.advisoryOnly &&
              !latestEvaluation.playbackMutation &&
              coordinator.length == 0 &&
              monitor.isDisposed &&
              poller.isDisposed &&
              controller.isDisposed &&
              monitorDisposedPollerAlive &&
              monitorDisposedControllerAlive &&
              pollerDisposedControllerAlive;
        } catch (error, stack) {
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_MULTI_PROTOCOL_RESILIENCE_COORDINATOR_PUBLIC_API_${testCase.key.toUpperCase()}_ERROR: $error\n$stack',
          );
          casePass = false;
        } finally {
          await monitorSub?.cancel();
          if (monitor != null && !monitor.isDisposed) {
            try {
              await monitor.dispose();
            } catch (_) {}
          }
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
          'snapshotsCount': collectedSnapshots.length,
          'playbackProgressObserved': playbackProgressObserved,
          'maxRenderedFrames': maxRenderedFrames,
          'maxPositionMs': maxPositionMs,
          'maxBufferedPositionMs': maxBufferedPositionMs,
          'sawPlaying': sawPlaying,
          'coordinatorEvaluation': coordinatorEvalDiag,
          'latestStatus': latestStatusDiag,
          'lifecycleBoundaries': {
            'monitorDisposedPollerAlive': monitorDisposedPollerAlive,
            'monitorDisposedControllerAlive': monitorDisposedControllerAlive,
            'pollerDisposedControllerAlive': pollerDisposedControllerAlive,
            'monitorDisposed': monitor?.isDisposed ?? false,
            'pollerDisposed': poller?.isDisposed ?? false,
            'controllerDisposed': controller?.isDisposed ?? false,
          },
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
        'ANDROID_STREAMING_MULTI_PROTOCOL_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
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
      'hlsSnapshotsCount': caseResults['hls']?['snapshotsCount'] ?? 0,
      'dashSnapshotsCount': caseResults['dash']?['snapshotsCount'] ?? 0,
      'llHlsSnapshotsCount': caseResults['ll_hls']?['snapshotsCount'] ?? 0,
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
      'nonClaims': {
        'realRetryExecuted': false,
        'recordHostRetryAttemptedCalled': false,
        'protocolCoverage': 'hls_dash_ll_hls',
        'advisoryOnly': true,
      },
    };

    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_MULTI_PROTOCOL_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_MULTI_PROTOCOL_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_MULTI_PROTOCOL_RESILIENCE_COORDINATOR_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Multi-Protocol Resilience Coordinator Verified (HLS: OK, DASH: OK, LL-HLS: OK)'
            : 'FAIL: Multi-Protocol Resilience Coordinator Smoke Failed';
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
