// Vanguard iOS True-DAG Phase 4C8B: Public streaming playback API physical smoke test.
//
// Sequentially verifies AVPlayer HLS / LL-HLS playback and DASH typed deferral
// using the public VGStreamingPlaybackClient API on physical iOS hardware:
//   1. HLS (Mux public test stream) with constrained profile & full controls (pause, play, seek, stop, dispose).
//   2. LL-HLS (Mux public low-latency stream) with lowLatency profile.
//   3. DASH (Shaka demo Angel One stream) with typed unsupported deferral verification.
//
// Platform Facts & Invariants:
// - Physical iOS device execution only.
// - Uses public VGStreamingPlaybackClient / VGStreamingPlaybackOptions only.
// - Every async operation uses bounded timeout.
// - Emits structured log markers and terminal JSON payload.
// - Exit 0 on pass, exit 1 on failure.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const int _initialWidth = 640;
const int _initialHeight = 360;
const Duration _kOperationTimeout = Duration(seconds: 15);
const Duration _kControlTimeout = Duration(seconds: 8);
const Duration _kPollInterval = Duration(milliseconds: 300);

void main() {
  runApp(const IosStreamingPlaybackPublicApiPhysicalSmokeApp());
}

class IosStreamingPlaybackPublicApiPhysicalSmokeApp extends StatefulWidget {
  const IosStreamingPlaybackPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingPlaybackPublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingPlaybackPublicApiPhysicalSmokeAppState();
}

class _IosStreamingPlaybackPublicApiPhysicalSmokeAppState
    extends State<IosStreamingPlaybackPublicApiPhysicalSmokeApp> {
  final VGStreamingPlaybackClient _client = VGStreamingPlaybackClient();
  String _status = 'Bootstrapping iOS streaming playback smoke...';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    // ignore: avoid_print
    print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_PUBLIC_API_BOOTSTRAP_ERROR: $error\n$stack',
        );
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_PHYSICAL_FAIL');
        exit(1);
      }
    });
  }

  Future<void> _runSmoke() async {
    final results = <String, dynamic>{
      'phase': 'Phase4C8B',
      'target': 'ios_physical',
    };
    bool allPass = false;

    int hlsRenderedFrames = 0;
    int llHlsRenderedFrames = 0;
    String dashRaw = '';

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Case 1: HLS Playback & Control Pipeline
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_OPEN: START');
      if (mounted) {
        setState(() {
          _status = 'Opening HLS stream…';
        });
      }

      final hlsSession = await _client
          .open(
            VGStreamingPlaybackOptions(
              uri: Uri.parse(
                'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
              ),
              initialWidth: _initialWidth,
              initialHeight: _initialHeight,
              formatHint: VGStreamingFormatHint.hls,
              networkProfile: VGStreamingNetworkProfile.constrained,
              autoPlay: true,
            ),
          )
          .timeout(_kOperationTimeout);

      if (!hlsSession.pass || hlsSession.textureId < 0) {
        throw Exception(
          'HLS open failed: pass=${hlsSession.pass}, textureId=${hlsSession.textureId}, raw=${hlsSession.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_OPEN: DONE (textureId=${hlsSession.textureId})',
      );

      if (mounted) {
        setState(() {
          _textureId = hlsSession.textureId;
          _status = 'HLS streaming active (textureId=${hlsSession.textureId})…';
        });
      }

      try {
        // Poll status until frames render
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_STATUS: START');
        final hlsDeadline = DateTime.now().add(_kOperationTimeout);
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
          'textureId': finalHlsStatus.textureId,
          'renderedFrames': finalHlsStatus.renderedFrames,
          'state': finalHlsStatus.state.name,
          'displayWidth': finalHlsStatus.displayWidth,
          'displayHeight': finalHlsStatus.displayHeight,
          'effectiveDisplayWidth': finalHlsStatus.effectiveDisplayWidth,
          'effectiveDisplayHeight': finalHlsStatus.effectiveDisplayHeight,
          'rotationDegrees': finalHlsStatus.rotationDegrees,
          'durationMs': finalHlsStatus.durationMs,
          'positionMs': finalHlsStatus.positionMs,
          'bufferedPositionMs': finalHlsStatus.bufferedPositionMs,
          'bufferedPercent': finalHlsStatus.bufferedPercent,
          'raw': finalHlsStatus.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_STATUS: DONE (renderedFrames=$hlsRenderedFrames, state=${finalHlsStatus.state.name}, dims=${finalHlsStatus.effectiveDisplayWidth}x${finalHlsStatus.effectiveDisplayHeight})',
        );

        // Pause
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_PAUSE: START');
        final pausedSession = await _client
            .pause(hlsSession)
            .timeout(_kControlTimeout);
        if (!pausedSession.pass ||
            pausedSession.state != VGStreamingPlaybackState.paused) {
          throw Exception(
            'HLS pause failed: pass=${pausedSession.pass}, state=${pausedSession.state.name}',
          );
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_PAUSE: DONE');

        // Play
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_PLAY: START');
        final resumedSession = await _client
            .play(hlsSession)
            .timeout(_kControlTimeout);
        if (!resumedSession.pass ||
            resumedSession.state == VGStreamingPlaybackState.failed) {
          throw Exception(
            'HLS play failed: pass=${resumedSession.pass}, state=${resumedSession.state.name}',
          );
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_PLAY: DONE');

        // Seek
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_SEEK: START');
        final seekSession = await _client
            .seek(hlsSession, 1000)
            .timeout(_kControlTimeout);
        if (!seekSession.pass ||
            seekSession.state == VGStreamingPlaybackState.failed) {
          throw Exception(
            'HLS seek failed: pass=${seekSession.pass}, state=${seekSession.state.name}',
          );
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_SEEK: DONE');

        // Stop
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_STOP: START');
        final stopSession = await _client
            .stop(hlsSession)
            .timeout(_kControlTimeout);
        if (!stopSession.pass ||
            stopSession.state != VGStreamingPlaybackState.idle) {
          throw Exception(
            'HLS stop failed: pass=${stopSession.pass}, state=${stopSession.state.name}',
          );
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_STOP: DONE');
      } finally {
        // Dispose HLS session
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_DISPOSE: START');
        if (hlsSession.textureId >= 0) {
          await _client.dispose(hlsSession).timeout(_kControlTimeout);
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_HLS_DISPOSE: DONE');
        if (mounted) {
          setState(() {
            _textureId = null;
          });
        }
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Case 2: LL-HLS Low-Latency Playback
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_LL_HLS_OPEN: START');
      if (mounted) {
        setState(() {
          _status = 'Opening LL-HLS stream…';
        });
      }

      final llSession = await _client
          .open(
            VGStreamingPlaybackOptions(
              uri: Uri.parse(
                'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
              ),
              initialWidth: _initialWidth,
              initialHeight: _initialHeight,
              formatHint: VGStreamingFormatHint.hls,
              networkProfile: VGStreamingNetworkProfile.lowLatency,
              autoPlay: true,
            ),
          )
          .timeout(_kOperationTimeout);

      if (!llSession.pass || llSession.textureId < 0) {
        throw Exception(
          'LL-HLS open failed: pass=${llSession.pass}, textureId=${llSession.textureId}, raw=${llSession.raw}',
        );
      }

      // ignore: avoid_print
      print(
        'IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_LL_HLS_OPEN: DONE (textureId=${llSession.textureId})',
      );

      if (mounted) {
        setState(() {
          _textureId = llSession.textureId;
          _status =
              'LL-HLS streaming active (textureId=${llSession.textureId})…';
        });
      }

      try {
        // Poll status until frames render
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_LL_HLS_STATUS: START');
        final llDeadline = DateTime.now().add(_kOperationTimeout);
        VGStreamingPlaybackSession? finalLlStatus;

        while (DateTime.now().isBefore(llDeadline)) {
          final status = await _client
              .getStatus(llSession)
              .timeout(_kControlTimeout);
          if (status.renderedFrames > 0 &&
              status.effectiveDisplayWidth > 0 &&
              status.effectiveDisplayHeight > 0 &&
              status.state != VGStreamingPlaybackState.failed &&
              status.state != VGStreamingPlaybackState.surfaceLost &&
              status.state != VGStreamingPlaybackState.unsupported) {
            finalLlStatus = status;
            break;
          }
          await Future<void>.delayed(_kPollInterval);
        }

        if (finalLlStatus == null) {
          final lastStatus = await _client
              .getStatus(llSession)
              .timeout(_kControlTimeout);
          throw Exception(
            'LL-HLS status verification timed out: renderedFrames=${lastStatus.renderedFrames}, '
            'state=${lastStatus.state.name}, effectiveDisplayWidth=${lastStatus.effectiveDisplayWidth}, '
            'effectiveDisplayHeight=${lastStatus.effectiveDisplayHeight}, raw=${lastStatus.raw}',
          );
        }

        llHlsRenderedFrames = finalLlStatus.renderedFrames;
        results['llHls'] = <String, dynamic>{
          'pass': true,
          'textureId': finalLlStatus.textureId,
          'renderedFrames': finalLlStatus.renderedFrames,
          'state': finalLlStatus.state.name,
          'displayWidth': finalLlStatus.displayWidth,
          'displayHeight': finalLlStatus.displayHeight,
          'effectiveDisplayWidth': finalLlStatus.effectiveDisplayWidth,
          'effectiveDisplayHeight': finalLlStatus.effectiveDisplayHeight,
          'rotationDegrees': finalLlStatus.rotationDegrees,
          'durationMs': finalLlStatus.durationMs,
          'positionMs': finalLlStatus.positionMs,
          'bufferedPositionMs': finalLlStatus.bufferedPositionMs,
          'bufferedPercent': finalLlStatus.bufferedPercent,
          'raw': finalLlStatus.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_LL_HLS_STATUS: DONE (renderedFrames=$llHlsRenderedFrames, state=${finalLlStatus.state.name}, dims=${finalLlStatus.effectiveDisplayWidth}x${finalLlStatus.effectiveDisplayHeight})',
        );
      } finally {
        // Dispose LL-HLS session
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_LL_HLS_DISPOSE: START');
        if (llSession.textureId >= 0) {
          await _client.dispose(llSession).timeout(_kControlTimeout);
        }
        // ignore: avoid_print
        print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_LL_HLS_DISPOSE: DONE');
        if (mounted) {
          setState(() {
            _textureId = null;
          });
        }
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Case 3: DASH Typed Deferral Verification
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_DASH_UNSUPPORTED: START');
      if (mounted) {
        setState(() {
          _status = 'Testing DASH typed deferral…';
        });
      }

      final dashSession = await _client
          .open(
            VGStreamingPlaybackOptions(
              uri: Uri.parse(
                'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
              ),
              initialWidth: _initialWidth,
              initialHeight: _initialHeight,
              formatHint: VGStreamingFormatHint.dash,
            ),
          )
          .timeout(_kOperationTimeout);

      dashRaw = dashSession.raw;
      final dashPass =
          !dashSession.pass &&
          dashSession.textureId < 0 &&
          dashSession.format == VGStreamingFormatHint.dash &&
          (dashSession.state == VGStreamingPlaybackState.failed ||
              dashSession.state == VGStreamingPlaybackState.unsupported) &&
          dashSession.raw.contains('unsupported_format') &&
          dashSession.raw.contains('platform=ios');

      if (!dashPass) {
        throw Exception(
          'DASH typed deferral check failed: pass=${dashSession.pass}, '
          'textureId=${dashSession.textureId}, format=${dashSession.format.name}, '
          'state=${dashSession.state.name}, raw=${dashSession.raw}',
        );
      }

      results['dash'] = <String, dynamic>{
        'pass': true,
        'textureId': dashSession.textureId,
        'format': dashSession.format.name,
        'state': dashSession.state.name,
        'raw': dashSession.raw,
      };

      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_PUBLIC_API_STEP_DASH_UNSUPPORTED: DONE');

      allPass = true;
      results['pass'] = true;
      results['hlsPass'] = true;
      results['llHlsPass'] = true;
      results['dashPass'] = true;
      results['hlsRenderedFrames'] = hlsRenderedFrames;
      results['llHlsRenderedFrames'] = llHlsRenderedFrames;
      results['dashRaw'] = dashRaw;
    } catch (error, stack) {
      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack');
      results['pass'] = false;
      results['error'] = error.toString();
      allPass = false;
    }

    // Emit terminal JSON line
    // ignore: avoid_print
    print(
      'IOS_STREAMING_PLAYBACK_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_PLAYBACK_PUBLIC_API_PHYSICAL_FAIL');
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (HLS: $hlsRenderedFrames frames, LL-HLS: $llHlsRenderedFrames frames, DASH: unsupported deferred)'
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
