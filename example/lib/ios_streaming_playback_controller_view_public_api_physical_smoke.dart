// Vanguard iOS True-DAG Phase 4C8E: Public streaming playback controller + texture view physical smoke test.
//
// Sequentially verifies:
//   1. Definition of candidate streams (DASH, HLS, LL-HLS) via pure-Dart VGStreamingSourceSet.
//   2. Composition with synthetic advisory preflight report.
//   3. Case 1 (HLS fallback): VGStreamingPlaybackDecisionPlanner with preferDash and appleAvPlayer capability
//      avoids DASH, logs warning 'source_incompatible:dash:dash_not_supported', selects HLS,
//      and opens physical AVPlayer playback via VGStreamingPlaybackController and VGStreamingPlaybackTextureView.
//      Executes lifecycle controls: pause(), optional bounded seek(), play(), stop(), dispose().
//   4. Case 2 (LL-HLS selection): VGStreamingPlaybackDecisionPlanner with preferHls, preferredKeys: ['ll_hls'],
//      and appleAvPlayer(preferLowLatency: true) selects LL-HLS, opens physical playback via controller + view,
//      polls status refresh, and disposes cleanly.
//
// Verification Invariants & Boundaries:
// - Imports ONLY:
//   - dart:async
//   - dart:convert
//   - dart:io
//   - package:flutter/material.dart
//   - package:vanguard_media_engine/vanguard_media_engine.dart
// - No raw MethodChannel or package:flutter/services.dart.
// - Pure-Dart capability-aware decision planning with synthetic advisory preflight report.
// - Bounded timeouts across all operations.
// - Controller session lifecycle rendered exclusively via VGStreamingPlaybackTextureView (no direct raw Texture widget).
// - Always disposes playback controllers in finally blocks.
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

void main() {
  runApp(const IosStreamingPlaybackControllerViewPublicApiPhysicalSmokeApp());
}

class IosStreamingPlaybackControllerViewPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingPlaybackControllerViewPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<IosStreamingPlaybackControllerViewPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingPlaybackControllerViewPublicApiPhysicalSmokeAppState();
}

class _IosStreamingPlaybackControllerViewPublicApiPhysicalSmokeAppState
    extends State<IosStreamingPlaybackControllerViewPublicApiPhysicalSmokeApp> {
  String _status =
      'Bootstrapping iOS streaming playback controller + view smoke...';
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
    print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_BOOTSTRAP_ERROR: $error\n$stack',
        );
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_PUBLIC_API_PHYSICAL_FAIL',
        );
        exit(1);
      }
    });
  }

  Future<void> _runSmoke() async {
    final results = <String, dynamic>{
      'phase': 'Phase4C8E',
      'target': 'ios_physical',
    };
    bool allPass = false;

    int hlsRenderedFrames = 0;
    int llHlsRenderedFrames = 0;

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Setup: Source Set & Synthetic Preflight Advisory Report
      // ═══════════════════════════════════════════════════════════════════════
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
            requireLlHlsTags: true,
            initialWidth: _initialWidth,
            initialHeight: _initialHeight,
          ),
        ],
      );

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

      // ═══════════════════════════════════════════════════════════════════════
      // Case 1: HLS fallback (preferDash + appleAvPlayer -> HLS selected)
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_PLAN: START');
      if (mounted) {
        setState(() {
          _status = 'Case 1: Planning HLS fallback from preferDash...';
        });
      }

      final hlsDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: syntheticPreflightReport,
          preference: VGStreamingSourceSelectionPreference.preferDash,
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(),
        ),
      );

      if (!hlsDecision.canOpenPlayback ||
          hlsDecision.decision != 'playback_ready' ||
          hlsDecision.selectedKey != 'hls' ||
          hlsDecision.playbackOptions?.formatHint !=
              VGStreamingFormatHint.hls ||
          !hlsDecision.warnings.contains(
            'source_incompatible:dash:dash_not_supported',
          )) {
        throw Exception(
          'HLS decision plan assertion failed: canOpenPlayback=${hlsDecision.canOpenPlayback}, '
          'decision=${hlsDecision.decision}, selectedKey=${hlsDecision.selectedKey}, '
          'formatHint=${hlsDecision.playbackOptions?.formatHint}, warnings=${hlsDecision.warnings}',
        );
      }

      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_PLAN: DONE');

      // Create fresh controller for Case 1
      VGStreamingPlaybackController? hlsController =
          VGStreamingPlaybackController();

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_OPEN: START');
        if (mounted) {
          setState(() {
            _status = 'Case 1: Opening selected HLS playback controller...';
          });
        }

        final hlsOpenSnapshot = await hlsController
            .open(hlsDecision, startPlayback: true)
            .timeout(_kOperationTimeout);

        if (!hlsOpenSnapshot.pass || hlsOpenSnapshot.textureId == null) {
          throw Exception(
            'HLS controller open failed: pass=${hlsOpenSnapshot.pass}, '
            'reason=${hlsOpenSnapshot.reason}, lastError=${hlsOpenSnapshot.lastError}, '
            'textureId=${hlsOpenSnapshot.textureId}',
          );
        }

        if (mounted) {
          setState(() {
            _currentSnapshot = hlsOpenSnapshot;
            _status =
                'Case 1: HLS streaming active (textureId=${hlsOpenSnapshot.textureId})...';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_OPEN: DONE (textureId=${hlsOpenSnapshot.textureId})',
        );

        // Poll controller.refresh() until renderedFrames > 0
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_STATUS: START');
        final hlsDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackControllerSnapshot? finalHlsSnapshot;

        while (DateTime.now().isBefore(hlsDeadline)) {
          final refreshed = await hlsController.refresh().timeout(
            _kControlTimeout,
          );
          if (mounted) {
            setState(() {
              _currentSnapshot = refreshed;
            });
          }

          final session = refreshed.session;
          if (session != null &&
              session.renderedFrames > 0 &&
              session.effectiveDisplayWidth > 0 &&
              session.effectiveDisplayHeight > 0 &&
              refreshed.state != VGStreamingPlaybackControllerState.failed &&
              refreshed.state !=
                  VGStreamingPlaybackControllerState.unsupported) {
            finalHlsSnapshot = refreshed;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (finalHlsSnapshot == null) {
          final lastRefreshed = await hlsController.refresh().timeout(
            _kControlTimeout,
          );
          throw Exception(
            'HLS status verification timed out: renderedFrames=${lastRefreshed.session?.renderedFrames}, '
            'state=${lastRefreshed.state.name}, dims=${lastRefreshed.session?.effectiveDisplayWidth}x${lastRefreshed.session?.effectiveDisplayHeight}, '
            'raw=${lastRefreshed.session?.raw}',
          );
        }

        final hlsSession = finalHlsSnapshot.session!;
        hlsRenderedFrames = hlsSession.renderedFrames;

        // Telemetry assertions
        final durationMs = finalHlsSnapshot.durationMs;
        final positionMs = finalHlsSnapshot.positionMs;
        final bufferedPositionMs = finalHlsSnapshot.bufferedPositionMs;
        final bufferedPercent = finalHlsSnapshot.bufferedPercent;
        final hasPlaybackTelemetry = finalHlsSnapshot.hasPlaybackTelemetry;

        final telemetryValid =
            hasPlaybackTelemetry &&
            durationMs >= -1 &&
            positionMs >= 0 &&
            bufferedPositionMs >= 0 &&
            bufferedPercent >= 0 &&
            bufferedPercent <= 100;

        if (!telemetryValid) {
          throw Exception(
            'HLS telemetry assertion failed: hasPlaybackTelemetry=$hasPlaybackTelemetry, '
            'durationMs=$durationMs, positionMs=$positionMs, bufferedPositionMs=$bufferedPositionMs, '
            'bufferedPercent=$bufferedPercent',
          );
        }

        results['hls'] = <String, dynamic>{
          'pass': true,
          'selectedKey': hlsDecision.selectedKey,
          'textureId': finalHlsSnapshot.textureId,
          'renderedFrames': hlsSession.renderedFrames,
          'state': finalHlsSnapshot.state.name,
          'effectiveDisplayWidth': hlsSession.effectiveDisplayWidth,
          'effectiveDisplayHeight': hlsSession.effectiveDisplayHeight,
          'durationMs': durationMs,
          'positionMs': positionMs,
          'bufferedPositionMs': bufferedPositionMs,
          'bufferedPercent': bufferedPercent,
          'hasPlaybackTelemetry': hasPlaybackTelemetry,
          'warnings': hlsDecision.warnings,
          'raw': hlsSession.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_STATUS: DONE (renderedFrames=$hlsRenderedFrames, dims=${hlsSession.effectiveDisplayWidth}x${hlsSession.effectiveDisplayHeight})',
        );

        // Pause
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_PAUSE: START');
        final pauseSnapshot = await hlsController.pause().timeout(
          _kControlTimeout,
        );
        if (!pauseSnapshot.pass ||
            pauseSnapshot.state != VGStreamingPlaybackControllerState.paused) {
          throw Exception(
            'HLS controller pause failed: pass=${pauseSnapshot.pass}, state=${pauseSnapshot.state.name}, reason=${pauseSnapshot.reason}',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = pauseSnapshot;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_PAUSE: DONE');

        // Optional Seek (only when durationMs > 2000)
        if (durationMs > 2000) {
          final seekTargetMs = (durationMs ~/ 4).clamp(1000, 8000);
          final seekSnapshot = await hlsController
              .seek(seekTargetMs)
              .timeout(_kControlTimeout);
          if (!seekSnapshot.pass ||
              seekSnapshot.state == VGStreamingPlaybackControllerState.failed) {
            throw Exception(
              'HLS controller seek failed: pass=${seekSnapshot.pass}, state=${seekSnapshot.state.name}, reason=${seekSnapshot.reason}',
            );
          }
          if (mounted) {
            setState(() {
              _currentSnapshot = seekSnapshot;
            });
          }
        }

        // Play
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_PLAY: START');
        final playSnapshot = await hlsController.play().timeout(
          _kControlTimeout,
        );
        if (!playSnapshot.pass ||
            playSnapshot.state == VGStreamingPlaybackControllerState.failed) {
          throw Exception(
            'HLS controller play resume failed: pass=${playSnapshot.pass}, state=${playSnapshot.state.name}, reason=${playSnapshot.reason}',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = playSnapshot;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_PLAY: DONE');

        // Stop
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_STOP: START');
        final stopSnapshot = await hlsController.stop().timeout(
          _kControlTimeout,
        );
        if (!stopSnapshot.pass ||
            stopSnapshot.state != VGStreamingPlaybackControllerState.stopped) {
          throw Exception(
            'HLS controller stop failed: pass=${stopSnapshot.pass}, state=${stopSnapshot.state.name}, reason=${stopSnapshot.reason}',
          );
        }
        if (mounted) {
          setState(() {
            _currentSnapshot = stopSnapshot;
          });
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_STOP: DONE');
      } finally {
        // Dispose HLS controller
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_DISPOSE: START');
        if (!hlsController.isDisposed) {
          final disposeSnapshot = await hlsController.dispose().timeout(
            _kControlTimeout,
          );
          if (mounted) {
            setState(() {
              _currentSnapshot = disposeSnapshot;
            });
          }
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_HLS_DISPOSE: DONE');
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Case 2: LL-HLS Low-Latency Selection
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_LL_HLS_PLAN: START');
      if (mounted) {
        setState(() {
          _status = 'Case 2: Planning LL-HLS low-latency selection...';
        });
      }

      final llHlsDecision = VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: syntheticPreflightReport,
          preference: VGStreamingSourceSelectionPreference.preferHls,
          preferredKeys: const ['ll_hls'],
          clientCapabilities:
              const VGStreamingSourceClientCapabilities.appleAvPlayer(
                preferLowLatency: true,
              ),
        ),
      );

      if (!llHlsDecision.canOpenPlayback ||
          llHlsDecision.decision != 'playback_ready' ||
          llHlsDecision.selectedKey != 'll_hls' ||
          llHlsDecision.playbackOptions?.formatHint !=
              VGStreamingFormatHint.hls ||
          llHlsDecision.selectedSource?.requireLlHlsTags != true) {
        throw Exception(
          'LL-HLS decision plan assertion failed: canOpenPlayback=${llHlsDecision.canOpenPlayback}, '
          'decision=${llHlsDecision.decision}, selectedKey=${llHlsDecision.selectedKey}, '
          'formatHint=${llHlsDecision.playbackOptions?.formatHint}, '
          'requireLlHlsTags=${llHlsDecision.selectedSource?.requireLlHlsTags}, '
          'warnings=${llHlsDecision.warnings}',
        );
      }

      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_LL_HLS_PLAN: DONE');

      // Create fresh controller for Case 2
      VGStreamingPlaybackController? llHlsController =
          VGStreamingPlaybackController();

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_LL_HLS_OPEN: START');
        if (mounted) {
          setState(() {
            _status = 'Case 2: Opening selected LL-HLS playback controller...';
          });
        }

        final llHlsOpenSnapshot = await llHlsController
            .open(llHlsDecision, startPlayback: true)
            .timeout(_kOperationTimeout);

        if (!llHlsOpenSnapshot.pass || llHlsOpenSnapshot.textureId == null) {
          throw Exception(
            'LL-HLS controller open failed: pass=${llHlsOpenSnapshot.pass}, '
            'reason=${llHlsOpenSnapshot.reason}, lastError=${llHlsOpenSnapshot.lastError}, '
            'textureId=${llHlsOpenSnapshot.textureId}',
          );
        }

        if (mounted) {
          setState(() {
            _currentSnapshot = llHlsOpenSnapshot;
            _status =
                'Case 2: LL-HLS streaming active (textureId=${llHlsOpenSnapshot.textureId})...';
          });
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_LL_HLS_OPEN: DONE (textureId=${llHlsOpenSnapshot.textureId})',
        );

        // Poll controller.refresh() until renderedFrames > 0
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_LL_HLS_STATUS: START',
        );
        final llHlsDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackControllerSnapshot? finalLlHlsSnapshot;

        while (DateTime.now().isBefore(llHlsDeadline)) {
          final refreshed = await llHlsController.refresh().timeout(
            _kControlTimeout,
          );
          if (mounted) {
            setState(() {
              _currentSnapshot = refreshed;
            });
          }

          final session = refreshed.session;
          if (session != null &&
              session.renderedFrames > 0 &&
              session.effectiveDisplayWidth > 0 &&
              session.effectiveDisplayHeight > 0 &&
              refreshed.state != VGStreamingPlaybackControllerState.failed &&
              refreshed.state !=
                  VGStreamingPlaybackControllerState.unsupported) {
            finalLlHlsSnapshot = refreshed;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (finalLlHlsSnapshot == null) {
          final lastRefreshed = await llHlsController.refresh().timeout(
            _kControlTimeout,
          );
          throw Exception(
            'LL-HLS status verification timed out: renderedFrames=${lastRefreshed.session?.renderedFrames}, '
            'state=${lastRefreshed.state.name}, dims=${lastRefreshed.session?.effectiveDisplayWidth}x${lastRefreshed.session?.effectiveDisplayHeight}, '
            'raw=${lastRefreshed.session?.raw}',
          );
        }

        final llHlsSession = finalLlHlsSnapshot.session!;
        llHlsRenderedFrames = llHlsSession.renderedFrames;

        final durationMs = finalLlHlsSnapshot.durationMs;
        final positionMs = finalLlHlsSnapshot.positionMs;
        final bufferedPositionMs = finalLlHlsSnapshot.bufferedPositionMs;
        final bufferedPercent = finalLlHlsSnapshot.bufferedPercent;
        final hasPlaybackTelemetry = finalLlHlsSnapshot.hasPlaybackTelemetry;

        final telemetryValid =
            hasPlaybackTelemetry &&
            durationMs >= -1 &&
            positionMs >= 0 &&
            bufferedPositionMs >= 0 &&
            bufferedPercent >= 0 &&
            bufferedPercent <= 100;

        if (!telemetryValid) {
          throw Exception(
            'LL-HLS telemetry assertion failed: hasPlaybackTelemetry=$hasPlaybackTelemetry, '
            'durationMs=$durationMs, positionMs=$positionMs, bufferedPositionMs=$bufferedPositionMs, '
            'bufferedPercent=$bufferedPercent',
          );
        }

        results['llHls'] = <String, dynamic>{
          'pass': true,
          'selectedKey': llHlsDecision.selectedKey,
          'textureId': finalLlHlsSnapshot.textureId,
          'renderedFrames': llHlsSession.renderedFrames,
          'state': finalLlHlsSnapshot.state.name,
          'effectiveDisplayWidth': llHlsSession.effectiveDisplayWidth,
          'effectiveDisplayHeight': llHlsSession.effectiveDisplayHeight,
          'durationMs': durationMs,
          'positionMs': positionMs,
          'bufferedPositionMs': bufferedPositionMs,
          'bufferedPercent': bufferedPercent,
          'hasPlaybackTelemetry': hasPlaybackTelemetry,
          'warnings': llHlsDecision.warnings,
          'raw': llHlsSession.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_LL_HLS_STATUS: DONE (renderedFrames=$llHlsRenderedFrames, dims=${llHlsSession.effectiveDisplayWidth}x${llHlsSession.effectiveDisplayHeight})',
        );
      } finally {
        // Dispose LL-HLS controller
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_LL_HLS_DISPOSE: START',
        );
        if (!llHlsController.isDisposed) {
          final disposeSnapshot = await llHlsController.dispose().timeout(
            _kControlTimeout,
          );
          if (mounted) {
            setState(() {
              _currentSnapshot = disposeSnapshot;
            });
          }
        }
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_STEP_LL_HLS_DISPOSE: DONE',
        );
      }

      allPass = true;
      results['pass'] = true;
      results['hlsPass'] = true;
      results['llHlsPass'] = true;
      results['hlsRenderedFrames'] = hlsRenderedFrames;
      results['llHlsRenderedFrames'] = llHlsRenderedFrames;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_PHYSICAL_ERROR: $error\n$stack',
      );
      results['pass'] = false;
      results['error'] = error.toString();
      allPass = false;
    }

    // Emit terminal JSON line
    // ignore: avoid_print
    print(
      'IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_CONTROLLER_VIEW_PUBLIC_API_PHYSICAL_FAIL');
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (HLS: $hlsRenderedFrames frames, LL-HLS: $llHlsRenderedFrames frames)'
            : 'FAIL: ${results['error']}';
      });
    }

    await Future<void>.delayed(const Duration(seconds: 1));
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
