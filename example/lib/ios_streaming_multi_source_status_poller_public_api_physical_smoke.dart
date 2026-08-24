// Copyright (c) Connects — Vanguard Phase 4C8H.
// iOS Public streaming playback multi-source status poller -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate stream set (DASH, HLS, LL-HLS) via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Composition with synthetic advisory preflight report for selector/controller/poller composition (no native preflight re-proof).
//   3. Case 1 (HLS fallback):
//      - Decision planning with preferDash under appleAvPlayer capabilities.
//      - Asserts decision is playback_ready, selects 'hls' with HLS formatHint, and emits dash_not_supported warning.
//      - Opens controller with startPlayback: true.
//      - Refreshes until renderedFrames > 0, positive display dimensions, and valid state.
//      - Attaches VGStreamingPlaybackStatusPoller (300ms interval, emitInitialSummary: true) and collects >= 2 summaries.
//      - Verifies summary bounds, poller stop, poller dispose (non-owning of controller), and safe refreshOnce after dispose.
//      - Explicitly stops and disposes controller.
//   4. Case 2 (LL-HLS selection):
//      - Decision planning with preferredKeys: ['ll_hls'] and appleAvPlayer(preferLowLatency: true).
//      - Asserts decision is playback_ready, selects 'll_hls' with HLS formatHint.
//      - Opens controller with startPlayback: true.
//      - Refreshes until renderedFrames > 0, positive display dimensions, and valid state.
//      - Attaches VGStreamingPlaybackStatusPoller (300ms interval, emitInitialSummary: true) and collects >= 2 summaries.
//      - Verifies summary bounds, poller stop, poller dispose (non-owning of controller), and safe refreshOnce after dispose.
//      - Explicitly stops and disposes controller.
//
// Verification Invariants & Boundaries:
// - Imports ONLY:
//   - dart:async
//   - dart:convert
//   - dart:io
//   - package:flutter/material.dart
//   - package:vanguard_media_engine/vanguard_media_engine.dart
// - Does NOT import package:flutter/services.dart.
// - Does NOT construct raw MethodChannel.
// - Render through VGStreamingPlaybackTextureView only (no raw Texture widget).
// - Synthetic preflight report used for selector/controller/poller composition only (no native preflight claim).
// - Bounded timeouts across all operations.
// - Per-case finally blocks for guaranteed subscription cancellation and safe cleanup.
// - Emits structured step markers and terminal JSON payload.
// - Exit 0 on pass, exit 1 on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const int _initialWidth = 640;
const int _initialHeight = 360;
const Duration _kOperationTimeout = Duration(seconds: 20);
const Duration _kControlTimeout = Duration(seconds: 8);
const Duration _kPollInterval = Duration(milliseconds: 300);
const Duration _kStatusDeadline = Duration(seconds: 20);
const Duration _kPollerCollectionTimeout = Duration(seconds: 15);

void main() {
  runApp(const IosStreamingMultiSourceStatusPollerPublicApiPhysicalSmokeApp());
}

class IosStreamingMultiSourceStatusPollerPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingMultiSourceStatusPollerPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<IosStreamingMultiSourceStatusPollerPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingMultiSourceStatusPollerPublicApiPhysicalSmokeAppState();
}

class _CaseConfig {
  const _CaseConfig({
    required this.caseName,
    required this.caseKey,
    required this.humanTitle,
    required this.request,
    required this.validateDecision,
  });

  final String caseName;
  final String caseKey;
  final String humanTitle;
  final VGStreamingPlaybackDecisionRequest request;
  final void Function(VGStreamingPlaybackDecision decision) validateDecision;
}

class _CaseExecutionResult {
  const _CaseExecutionResult({
    required this.pass,
    this.decision,
    this.textureId,
    this.renderedFrames = 0,
    this.summariesCount = 0,
    this.latestSummaryJson,
    this.rawSession,
    this.error,
  });

  final bool pass;
  final VGStreamingPlaybackDecision? decision;
  final int? textureId;
  final int renderedFrames;
  final int summariesCount;
  final Map<String, dynamic>? latestSummaryJson;
  final String? rawSession;
  final String? error;

  Map<String, dynamic> toJson() {
    if (pass) {
      return <String, dynamic>{
        'pass': true,
        'selectedKey': decision?.selectedKey,
        'textureId': textureId,
        'renderedFrames': renderedFrames,
        'summariesCount': summariesCount,
        'latestSummary': latestSummaryJson,
        'warnings': decision?.warnings ?? const <String>[],
        'raw': rawSession,
      };
    }
    return <String, dynamic>{'pass': false, 'error': error};
  }
}

class _IosStreamingMultiSourceStatusPollerPublicApiPhysicalSmokeAppState
    extends
        State<IosStreamingMultiSourceStatusPollerPublicApiPhysicalSmokeApp> {
  String _status =
      'Bootstrapping iOS multi-source streaming playback status poller smoke...';
  VGStreamingPlaybackControllerSnapshot _currentSnapshot =
      const VGStreamingPlaybackControllerSnapshot(
        state: VGStreamingPlaybackControllerState.idle,
        pass: true,
        reason: 'idle',
      );

  @override
  void initState() {
    super.initState();
    // ignore: avoid_print
    print('IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_BOOTSTRAP_ERROR: $error\n$stack',
        );
        // ignore: avoid_print
        print(
          'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_PUBLIC_API_PHYSICAL_FAIL',
        );
        exit(1);
      }
    });
  }

  void _updateUi(
    String status, {
    VGStreamingPlaybackControllerSnapshot? snapshot,
  }) {
    if (mounted) {
      setState(() {
        _status = status;
        if (snapshot != null) {
          _currentSnapshot = snapshot;
        }
      });
    }
  }

  Future<_CaseExecutionResult> _runTestCase(_CaseConfig config) async {
    VGStreamingPlaybackController? controller;
    VGStreamingPlaybackStatusPoller? poller;
    StreamSubscription<VGStreamingPlaybackStatusSummary>? pollerSub;
    final collectedSummaries = <VGStreamingPlaybackStatusSummary>[];

    try {
      // 1. Plan
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_PLAN: START',
      );
      _updateUi(
        '${config.humanTitle}: Planning decision...',
        snapshot: const VGStreamingPlaybackControllerSnapshot(
          state: VGStreamingPlaybackControllerState.idle,
          pass: true,
          reason: 'idle',
        ),
      );

      final decision = VGStreamingPlaybackDecisionPlanner.plan(config.request);
      config.validateDecision(decision);

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_PLAN: DONE',
      );

      // 2. Open
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_OPEN: START',
      );
      _updateUi('${config.humanTitle}: Opening playback controller...');

      controller = VGStreamingPlaybackController();
      final openSnapshot = await controller
          .open(decision, startPlayback: true)
          .timeout(_kOperationTimeout);

      if (!openSnapshot.pass || openSnapshot.textureId == null) {
        throw Exception(
          '${config.caseName} controller open failed: pass=${openSnapshot.pass}, '
          'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}, '
          'textureId=${openSnapshot.textureId}',
        );
      }

      _updateUi(
        '${config.humanTitle}: Controller active (textureId=${openSnapshot.textureId}), waiting for rendered frames...',
        snapshot: openSnapshot,
      );

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_OPEN: DONE (textureId=${openSnapshot.textureId})',
      );

      // 3. Status Wait
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_STATUS: START',
      );
      final deadline = DateTime.now().add(_kStatusDeadline);
      VGStreamingPlaybackControllerSnapshot? initialRenderedSnapshot;

      while (DateTime.now().isBefore(deadline)) {
        final refreshed = await controller.refresh().timeout(_kControlTimeout);
        _updateUi(_status, snapshot: refreshed);

        final session = refreshed.session;
        if (session != null &&
            session.renderedFrames > 0 &&
            session.effectiveDisplayWidth > 0 &&
            session.effectiveDisplayHeight > 0 &&
            refreshed.state != VGStreamingPlaybackControllerState.failed &&
            refreshed.state != VGStreamingPlaybackControllerState.unsupported) {
          initialRenderedSnapshot = refreshed;
          break;
        }
        await Future<void>.delayed(_kPollInterval);
      }

      if (initialRenderedSnapshot == null) {
        final lastRefreshed = await controller.refresh().timeout(
          _kControlTimeout,
        );
        throw Exception(
          '${config.caseName} initial status wait timed out: renderedFrames=${lastRefreshed.session?.renderedFrames}, '
          'state=${lastRefreshed.state.name}, dims=${lastRefreshed.session?.effectiveDisplayWidth}x${lastRefreshed.session?.effectiveDisplayHeight}, '
          'raw=${lastRefreshed.session?.raw}',
        );
      }

      final initialSession = initialRenderedSnapshot.session!;
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_STATUS: DONE (renderedFrames=${initialSession.renderedFrames}, dims=${initialSession.effectiveDisplayWidth}x${initialSession.effectiveDisplayHeight})',
      );

      // 4. Poller Start
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_POLLER_START: START',
      );
      _updateUi(
        '${config.humanTitle}: Instantiating and starting status poller...',
      );

      poller = VGStreamingPlaybackStatusPoller(
        controller: controller,
        config: VGStreamingPlaybackStatusPollerConfig(
          interval: const Duration(milliseconds: 300),
          emitInitialSummary: true,
        ),
      );

      pollerSub = poller.summaries.listen((summary) {
        collectedSummaries.add(summary);
        if (mounted && controller != null) {
          _updateUi(_status, snapshot: controller.snapshot);
        }
      });

      poller.start();
      if (!poller.isRunning) {
        throw Exception(
          '${config.caseName} poller failed to start (isRunning is false)',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_POLLER_START: DONE',
      );

      // 5. Collect & Invariants
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_COLLECT: START',
      );
      _updateUi(
        '${config.humanTitle}: Collecting status summaries from poller...',
      );

      final collectDeadline = DateTime.now().add(_kPollerCollectionTimeout);
      while (DateTime.now().isBefore(collectDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final latest = poller.latest;
        if (collectedSummaries.length >= 2 &&
            latest.hasSession &&
            latest.effectiveDisplayWidth > 0 &&
            latest.effectiveDisplayHeight > 0) {
          break;
        }
      }

      if (collectedSummaries.length < 2) {
        throw Exception(
          '${config.caseName} expected at least 2 emitted summaries, but collected ${collectedSummaries.length}',
        );
      }

      bool hasValidSessionSummary = false;
      for (final summary in collectedSummaries) {
        final durationValid = summary.durationMs >= -1;
        final positionValid = summary.positionMs >= 0;
        final bufferedPosValid = summary.bufferedPositionMs >= 0;
        final bufferedPercentValid =
            summary.bufferedPercent >= 0 && summary.bufferedPercent <= 100;
        final progressFractionValid =
            summary.progressFraction >= 0.0 && summary.progressFraction <= 1.0;
        final bufferedFractionValid =
            summary.bufferedFraction >= 0.0 && summary.bufferedFraction <= 1.0;

        if (!durationValid ||
            !positionValid ||
            !bufferedPosValid ||
            !bufferedPercentValid ||
            !progressFractionValid ||
            !bufferedFractionValid) {
          throw Exception(
            '${config.caseName} summary bounds violation: duration=${summary.durationMs}, '
            'position=${summary.positionMs}, bufferedPos=${summary.bufferedPositionMs}, '
            'bufferedPercent=${summary.bufferedPercent}, progressFraction=${summary.progressFraction}, '
            'bufferedFraction=${summary.bufferedFraction}',
          );
        }

        if (summary.hasSession &&
            summary.effectiveDisplayWidth > 0 &&
            summary.effectiveDisplayHeight > 0) {
          hasValidSessionSummary = true;
        }
      }

      if (!hasValidSessionSummary) {
        throw Exception(
          '${config.caseName}: none of the collected summaries satisfied hasSession==true with positive dimensions',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_COLLECT: DONE (collectedCount=${collectedSummaries.length})',
      );

      // 6. Poller Stop
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_POLLER_STOP: START',
      );
      poller.stop();
      if (poller.isRunning) {
        throw Exception(
          '${config.caseName} poller stop failed: isRunning is still true',
        );
      }
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_POLLER_STOP: DONE',
      );

      // 7. Poller Dispose
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_POLLER_DISPOSE: START',
      );
      await pollerSub.cancel();
      pollerSub = null;
      await poller.dispose();
      if (!poller.isDisposed) {
        throw Exception(
          '${config.caseName} poller dispose failed: isDisposed is false',
        );
      }

      if (controller.isDisposed) {
        throw Exception(
          '${config.caseName} poller dispose improperly disposed the underlying controller',
        );
      }

      // Safe refreshOnce() after dispose must not throw
      await poller.refreshOnce();

      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_POLLER_DISPOSE: DONE',
      );

      // 8. Controller Dispose
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_CONTROLLER_DISPOSE: START',
      );
      await controller.stop().timeout(_kControlTimeout);
      final disposeSnapshot = await controller.dispose().timeout(
        _kControlTimeout,
      );
      _updateUi(_status, snapshot: disposeSnapshot);
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_STEP_${config.caseName}_CONTROLLER_DISPOSE: DONE',
      );

      return _CaseExecutionResult(
        pass: true,
        decision: decision,
        textureId: openSnapshot.textureId,
        renderedFrames: initialRenderedSnapshot.session?.renderedFrames ?? 0,
        summariesCount: collectedSummaries.length,
        latestSummaryJson: poller.latest.toJson(),
        rawSession: initialRenderedSnapshot.session?.raw,
      );
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_${config.caseName}_ERROR: $error\n$stack',
      );
      return _CaseExecutionResult(pass: false, error: error.toString());
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
  }

  Future<void> _runSmoke() async {
    final caseResults = <String, dynamic>{};

    // Define Candidate Streams
    final sourceSet = VGStreamingSourceSet(
      sources: [
        VGStreamingSourceDescriptor(
          key: 'dash',
          uri: Uri.parse(
            'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
          ),
          formatHint: VGStreamingFormatHint.dash,
          initialWidth: _initialWidth,
          initialHeight: _initialHeight,
        ),
        VGStreamingSourceDescriptor(
          key: 'hls',
          uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
          formatHint: VGStreamingFormatHint.hls,
          initialWidth: _initialWidth,
          initialHeight: _initialHeight,
        ),
        VGStreamingSourceDescriptor(
          key: 'll_hls',
          uri: Uri.parse(
            'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
          ),
          formatHint: VGStreamingFormatHint.hls,
          initialWidth: _initialWidth,
          initialHeight: _initialHeight,
        ),
      ],
    );

    // Synthetic preflight report used for selector/controller/poller composition only
    const syntheticPreflightReport = VGStreamingPreflightReport(
      pass: true,
      phase: 'Phase4C5G',
      advisoryDecision: 'advise_stable',
      requestedNetworkProfile: 'AUTO',
      recommendedNetworkProfile: 'STABLE',
      recommendedNetworkPolicy: <String, Object?>{
        'profile': 'STABLE',
        'pass': true,
      },
      totalReports: 3,
      passedReports: 3,
      failedReports: 0,
      warnings: <String>[],
      deviceWarnings: <String>[],
      llHlsAvailable: true,
      advisoryOnly: true,
      playbackMutation: false,
      serverLadderPolicy: 'valid',
      iosMirrorNote: 'synthetic_preflight_for_selector_composition',
      raw: 'status=OK;phase=Phase4C5G',
      diagnostics: <String, Object?>{'pass': true, 'phase': 'Phase4C5G'},
    );

    // Case 1: HLS Fallback from preferDash
    final hlsCase = await _runTestCase(
      _CaseConfig(
        caseName: 'HLS_FALLBACK',
        caseKey: 'hls_fallback',
        humanTitle: 'Case 1/2 (HLS fallback)',
        request: VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: syntheticPreflightReport,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
        validateDecision: (decision) {
          if (!decision.canOpenPlayback ||
              decision.decision != 'playback_ready' ||
              decision.selectedKey != 'hls' ||
              decision.playbackOptions?.formatHint !=
                  VGStreamingFormatHint.hls ||
              !decision.warnings.contains(
                'source_incompatible:dash:dash_not_supported',
              )) {
            throw Exception(
              'HLS fallback planning assertion failed: canOpenPlayback=${decision.canOpenPlayback}, '
              'decision=${decision.decision}, selectedKey=${decision.selectedKey}, '
              'formatHint=${decision.playbackOptions?.formatHint}, warnings=${decision.warnings}',
            );
          }
        },
      ),
    );
    caseResults['hls_fallback'] = hlsCase.toJson();
    final hlsFallbackPass = hlsCase.pass;

    // Case 2: LL-HLS Selection
    final llHlsCase = await _runTestCase(
      _CaseConfig(
        caseName: 'LL_HLS',
        caseKey: 'll_hls',
        humanTitle: 'Case 2/2 (LL-HLS)',
        request: VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: syntheticPreflightReport,
          preference: VGStreamingSourceSelectionPreference.preferHls,
          preferredKeys: const ['ll_hls'],
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(
                preferLowLatency: true,
              ),
        ),
        validateDecision: (decision) {
          if (!decision.canOpenPlayback ||
              decision.decision != 'playback_ready' ||
              decision.selectedKey != 'll_hls' ||
              decision.playbackOptions?.formatHint !=
                  VGStreamingFormatHint.hls) {
            throw Exception(
              'LL-HLS planning assertion failed: canOpenPlayback=${decision.canOpenPlayback}, '
              'decision=${decision.decision}, selectedKey=${decision.selectedKey}, '
              'formatHint=${decision.playbackOptions?.formatHint}, warnings=${decision.warnings}',
            );
          }
        },
      ),
    );
    caseResults['ll_hls'] = llHlsCase.toJson();
    final llHlsPass = llHlsCase.pass;

    final allPass = hlsFallbackPass && llHlsPass;
    final results = <String, dynamic>{
      'phase': 'Phase4C8H',
      'target': 'ios_physical',
      'pass': allPass,
      'hlsFallbackPass': hlsFallbackPass,
      'llHlsPass': llHlsPass,
      'hlsFallback': caseResults['hls_fallback'],
      'llHls': caseResults['ll_hls'],
      'cases': caseResults,
    };

    // Emit final JSON marker
    // ignore: avoid_print
    print(
      'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_PUBLIC_API_PHYSICAL_PASS',
      );
    } else {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_MULTI_SOURCE_STATUS_POLLER_PUBLIC_API_PHYSICAL_FAIL',
      );
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Multi-Source Status Poller Verified (HLS Fallback: OK, LL-HLS: OK)'
            : 'FAIL: Multi-Source Status Poller Smoke Failed (HLS: $hlsFallbackPass, LL-HLS: $llHlsPass)';
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
