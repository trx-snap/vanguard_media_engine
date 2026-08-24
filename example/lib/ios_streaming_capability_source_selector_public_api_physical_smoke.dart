// Vanguard iOS True-DAG: Capability-aware streaming source selector public API physical smoke.
//
// Sequentially verifies:
//   1. Definition of candidate streams (DASH, HLS, LL-HLS) via pure-Dart VGStreamingSourceSet.
//   2. Case 1 (HLS fallback): VGStreamingPlaybackDecisionPlanner with preferDash and appleAvPlayer capability
//      avoids DASH, logs warning 'source_incompatible:dash:dash_not_supported', selects HLS,
//      and opens physical AVPlayer playback with rendered frames.
//   3. Case 2 (LL-HLS selection): VGStreamingPlaybackDecisionPlanner with preferHls and appleAvPlayer(preferLowLatency: true)
//      selects LL-HLS (requireLlHlsTags == true), and opens physical AVPlayer playback with rendered frames.
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
// - Always disposes playback sessions in finally blocks.
// - Emits structured log markers and terminal JSON payload.
// - Exit 0 on pass, exit 1 on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const int _initialWidth = 640;
const int _initialHeight = 360;
const Duration _kOpenTimeout = Duration(seconds: 20);
const Duration _kControlTimeout = Duration(seconds: 8);
const Duration _kPollInterval = Duration(milliseconds: 300);
const Duration _kStatusDeadline = Duration(seconds: 20);

void main() {
  runApp(const IosStreamingCapabilitySourceSelectorPublicApiPhysicalSmokeApp());
}

class IosStreamingCapabilitySourceSelectorPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingCapabilitySourceSelectorPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<IosStreamingCapabilitySourceSelectorPublicApiPhysicalSmokeApp>
  createState() =>
      _IosStreamingCapabilitySourceSelectorPublicApiPhysicalSmokeAppState();
}

class _IosStreamingCapabilitySourceSelectorPublicApiPhysicalSmokeAppState
    extends
        State<IosStreamingCapabilitySourceSelectorPublicApiPhysicalSmokeApp> {
  final VGStreamingPlaybackClient _client = VGStreamingPlaybackClient();
  String _status = 'Bootstrapping iOS capability selector smoke...';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    // ignore: avoid_print
    print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_CAPABILITY_SELECTOR_BOOTSTRAP_ERROR: $error\n$stack',
        );
        // ignore: avoid_print
        print('IOS_STREAMING_CAPABILITY_SELECTOR_PUBLIC_API_PHYSICAL_FAIL');
        exit(1);
      }
    });
  }

  Future<void> _runSmoke() async {
    final results = <String, dynamic>{
      'phase': 'Phase4C7K_Apple_AVPlayer_Capability_Selector',
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
      // Case 1: HLS fallback (DASH preferred on Apple AVPlayer -> HLS selected)
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_HLS_PLAN: START');
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
      print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_HLS_PLAN: DONE');

      // ignore: avoid_print
      print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_HLS_OPEN: START');
      if (mounted) {
        setState(() {
          _status = 'Case 1: Opening selected HLS playback...';
        });
      }

      final hlsSession = await _client
          .open(hlsDecision.playbackOptions!)
          .timeout(_kOpenTimeout);

      if (!hlsSession.pass || hlsSession.textureId < 0) {
        throw Exception(
          'HLS open failed: pass=${hlsSession.pass}, textureId=${hlsSession.textureId}, raw=${hlsSession.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CAPABILITY_SELECTOR_STEP_HLS_OPEN: DONE (textureId=${hlsSession.textureId})',
      );

      if (mounted) {
        setState(() {
          _textureId = hlsSession.textureId;
          _status =
              'Case 1: HLS streaming active (textureId=${hlsSession.textureId})...';
        });
      }

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_HLS_STATUS: START');
        final hlsDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackSession? finalHlsStatus;

        while (DateTime.now().isBefore(hlsDeadline)) {
          final status = await _client
              .getStatus(hlsSession)
              .timeout(_kControlTimeout);
          if (status.renderedFrames > 0 &&
              status.effectiveDisplayWidth > 0 &&
              status.effectiveDisplayHeight > 0 &&
              status.state != VGStreamingPlaybackState.failed &&
              status.state != VGStreamingPlaybackState.surfaceLost &&
              status.state != VGStreamingPlaybackState.unsupported) {
            finalHlsStatus = status;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (finalHlsStatus == null) {
          final lastStatus = await _client
              .getStatus(hlsSession)
              .timeout(_kControlTimeout);
          throw Exception(
            'HLS status verification timed out: renderedFrames=${lastStatus.renderedFrames}, '
            'state=${lastStatus.state.name}, effectiveDisplayWidth=${lastStatus.effectiveDisplayWidth}, '
            'effectiveDisplayHeight=${lastStatus.effectiveDisplayHeight}, raw=${lastStatus.raw}',
          );
        }

        hlsRenderedFrames = finalHlsStatus.renderedFrames;
        results['hls'] = <String, dynamic>{
          'pass': true,
          'selectedKey': hlsDecision.selectedKey,
          'textureId': finalHlsStatus.textureId,
          'renderedFrames': finalHlsStatus.renderedFrames,
          'state': finalHlsStatus.state.name,
          'effectiveDisplayWidth': finalHlsStatus.effectiveDisplayWidth,
          'effectiveDisplayHeight': finalHlsStatus.effectiveDisplayHeight,
          'warnings': hlsDecision.warnings,
          'raw': finalHlsStatus.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CAPABILITY_SELECTOR_STEP_HLS_STATUS: DONE (renderedFrames=$hlsRenderedFrames, dims=${finalHlsStatus.effectiveDisplayWidth}x${finalHlsStatus.effectiveDisplayHeight})',
        );
      } finally {
        // ignore: avoid_print
        print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_HLS_DISPOSE: START');
        if (hlsSession.textureId >= 0) {
          await _client.dispose(hlsSession).timeout(_kControlTimeout);
        }
        // ignore: avoid_print
        print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_HLS_DISPOSE: DONE');
        if (mounted) {
          setState(() {
            _textureId = null;
          });
        }
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Case 2: LL-HLS fallback / low-latency selection
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_LL_HLS_PLAN: START');
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
          'requireLlHlsTags=${llHlsDecision.selectedSource?.requireLlHlsTags}',
        );
      }

      // ignore: avoid_print
      print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_LL_HLS_PLAN: DONE');

      // ignore: avoid_print
      print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_LL_HLS_OPEN: START');
      if (mounted) {
        setState(() {
          _status = 'Case 2: Opening selected LL-HLS playback...';
        });
      }

      final llHlsSession = await _client
          .open(llHlsDecision.playbackOptions!)
          .timeout(_kOpenTimeout);

      if (!llHlsSession.pass || llHlsSession.textureId < 0) {
        throw Exception(
          'LL-HLS open failed: pass=${llHlsSession.pass}, textureId=${llHlsSession.textureId}, raw=${llHlsSession.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_CAPABILITY_SELECTOR_STEP_LL_HLS_OPEN: DONE (textureId=${llHlsSession.textureId})',
      );

      if (mounted) {
        setState(() {
          _textureId = llHlsSession.textureId;
          _status =
              'Case 2: LL-HLS streaming active (textureId=${llHlsSession.textureId})...';
        });
      }

      try {
        // ignore: avoid_print
        print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_LL_HLS_STATUS: START');
        final llHlsDeadline = DateTime.now().add(_kStatusDeadline);
        VGStreamingPlaybackSession? finalLlHlsStatus;

        while (DateTime.now().isBefore(llHlsDeadline)) {
          final status = await _client
              .getStatus(llHlsSession)
              .timeout(_kControlTimeout);
          if (status.renderedFrames > 0 &&
              status.effectiveDisplayWidth > 0 &&
              status.effectiveDisplayHeight > 0 &&
              status.state != VGStreamingPlaybackState.failed &&
              status.state != VGStreamingPlaybackState.surfaceLost &&
              status.state != VGStreamingPlaybackState.unsupported) {
            finalLlHlsStatus = status;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (finalLlHlsStatus == null) {
          final lastStatus = await _client
              .getStatus(llHlsSession)
              .timeout(_kControlTimeout);
          throw Exception(
            'LL-HLS status verification timed out: renderedFrames=${lastStatus.renderedFrames}, '
            'state=${lastStatus.state.name}, effectiveDisplayWidth=${lastStatus.effectiveDisplayWidth}, '
            'effectiveDisplayHeight=${lastStatus.effectiveDisplayHeight}, raw=${lastStatus.raw}',
          );
        }

        llHlsRenderedFrames = finalLlHlsStatus.renderedFrames;
        results['llHls'] = <String, dynamic>{
          'pass': true,
          'selectedKey': llHlsDecision.selectedKey,
          'textureId': finalLlHlsStatus.textureId,
          'renderedFrames': finalLlHlsStatus.renderedFrames,
          'state': finalLlHlsStatus.state.name,
          'effectiveDisplayWidth': finalLlHlsStatus.effectiveDisplayWidth,
          'effectiveDisplayHeight': finalLlHlsStatus.effectiveDisplayHeight,
          'warnings': llHlsDecision.warnings,
          'raw': finalLlHlsStatus.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_CAPABILITY_SELECTOR_STEP_LL_HLS_STATUS: DONE (renderedFrames=$llHlsRenderedFrames, dims=${finalLlHlsStatus.effectiveDisplayWidth}x${finalLlHlsStatus.effectiveDisplayHeight})',
        );
      } finally {
        // ignore: avoid_print
        print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_LL_HLS_DISPOSE: START');
        if (llHlsSession.textureId >= 0) {
          await _client.dispose(llHlsSession).timeout(_kControlTimeout);
        }
        // ignore: avoid_print
        print('IOS_STREAMING_CAPABILITY_SELECTOR_STEP_LL_HLS_DISPOSE: DONE');
        if (mounted) {
          setState(() {
            _textureId = null;
          });
        }
      }

      allPass = true;
      results['pass'] = true;
      results['hlsPass'] = true;
      results['llHlsPass'] = true;
      results['hlsRenderedFrames'] = hlsRenderedFrames;
      results['llHlsRenderedFrames'] = llHlsRenderedFrames;
    } catch (error, stack) {
      // ignore: avoid_print
      print('IOS_STREAMING_CAPABILITY_SELECTOR_PHYSICAL_ERROR: $error\n$stack');
      results['pass'] = false;
      results['error'] = error.toString();
      allPass = false;
    }

    // Emit terminal JSON line
    // ignore: avoid_print
    print(
      'IOS_STREAMING_CAPABILITY_SELECTOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_CAPABILITY_SELECTOR_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_CAPABILITY_SELECTOR_PUBLIC_API_PHYSICAL_FAIL');
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
              if (_textureId != null)
                SizedBox(
                  width: 320,
                  height: 180,
                  child: Texture(textureId: _textureId!),
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
