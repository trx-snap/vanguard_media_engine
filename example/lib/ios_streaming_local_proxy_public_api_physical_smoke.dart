// Vanguard iOS True-DAG Phase 4C6H2A: iOS local loopback streaming proxy pass-through proof.
//
// Sequentially verifies AVPlayer HLS / LL-HLS playback and DASH typed deferral
// using the public VGStreamingPlaybackClient API with VGPlaybackCacheOptions enabled on physical iOS hardware:
//   1. HLS (Mux public test stream) with constrained profile & cache enabled.
//   2. LL-HLS (Mux public low-latency stream) with lowLatency profile & cache enabled.
//   3. DASH (Shaka demo Angel One stream) with typed unsupported deferral verification.
//
// Platform Facts & Invariants:
// - Physical iOS device execution target.
// - Uses public VGStreamingPlaybackClient, VGStreamingPlaybackOptions, and VGPlaybackCacheOptions only.
// - Every async operation uses bounded timeout.
// - Guaranteed cleanup in finally blocks before exit.
// - Emits structured log markers and terminal JSON payload.
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

void main() {
  runApp(const IosStreamingLocalProxyPublicApiPhysicalSmokeApp());
}

class IosStreamingLocalProxyPublicApiPhysicalSmokeApp extends StatefulWidget {
  const IosStreamingLocalProxyPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingLocalProxyPublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingLocalProxyPublicApiPhysicalSmokeAppState();
}

class _IosStreamingLocalProxyPublicApiPhysicalSmokeAppState
    extends State<IosStreamingLocalProxyPublicApiPhysicalSmokeApp> {
  final VGStreamingPlaybackClient _client = VGStreamingPlaybackClient();
  String _status = 'Bootstrapping iOS streaming local proxy smoke...';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    // ignore: avoid_print
    print('IOS_STREAMING_LOCAL_PROXY_STEP_BOOTSTRAP: START');
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_BOOTSTRAP_ERROR: $error\n$stack');
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_PUBLIC_API_PHYSICAL_FAIL');
        exit(1);
      }
    });
  }

  Future<void> _runSmoke() async {
    final results = <String, dynamic>{
      'phase': 'Phase4C6H2A',
      'target': 'ios_physical',
    };
    bool allPass = false;

    int hlsRenderedFrames = 0;
    int hlsCacheBytesRead = 0;
    int llHlsRenderedFrames = 0;
    int llHlsCacheBytesRead = 0;
    String dashRaw = '';

    try {
      // ═══════════════════════════════════════════════════════════════════════
      // Case 1: HLS Proxy Pass-Through Playback
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_STEP_HLS_OPEN: START');
      if (mounted) {
        setState(() {
          _status = 'Opening HLS stream with local proxy cache enabled…';
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
              cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
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
        'IOS_STREAMING_LOCAL_PROXY_STEP_HLS_OPEN: DONE (textureId=${hlsSession.textureId})',
      );

      if (mounted) {
        setState(() {
          _textureId = hlsSession.textureId;
          _status =
              'HLS proxy streaming active (textureId=${hlsSession.textureId})…';
        });
      }

      try {
        // Poll status until frames render and cache telemetry is confirmed
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_STEP_HLS_STATUS: START');
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
              status.state != VGStreamingPlaybackState.unsupported &&
              status.playbackCacheEnabled == true &&
              status.playbackCacheTelemetryAttached == true &&
              status.playbackCacheIgnoredCount == 0 &&
              status.playbackCacheBytesRead > 0) {
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
            'HLS proxy pass-through verification timed out: '
            'renderedFrames=${lastStatus.renderedFrames}, '
            'state=${lastStatus.state.name}, '
            'effectiveDisplayWidth=${lastStatus.effectiveDisplayWidth}, '
            'effectiveDisplayHeight=${lastStatus.effectiveDisplayHeight}, '
            'playbackCacheEnabled=${lastStatus.playbackCacheEnabled}, '
            'playbackCacheTelemetryAttached=${lastStatus.playbackCacheTelemetryAttached}, '
            'playbackCacheIgnoredCount=${lastStatus.playbackCacheIgnoredCount}, '
            'playbackCacheBytesRead=${lastStatus.playbackCacheBytesRead}, '
            'raw=${lastStatus.raw}',
          );
        }

        hlsRenderedFrames = finalHlsStatus.renderedFrames;
        hlsCacheBytesRead = finalHlsStatus.playbackCacheBytesRead;
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
          'playbackCacheEnabled': finalHlsStatus.playbackCacheEnabled,
          'playbackCacheTelemetryAttached':
              finalHlsStatus.playbackCacheTelemetryAttached,
          'playbackCacheBytesRead': finalHlsStatus.playbackCacheBytesRead,
          'playbackCacheSizeBytes': finalHlsStatus.playbackCacheSizeBytes,
          'playbackCacheIgnoredCount': finalHlsStatus.playbackCacheIgnoredCount,
          'playbackCacheLastIgnoredReason':
              finalHlsStatus.playbackCacheLastIgnoredReason,
          'raw': finalHlsStatus.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_LOCAL_PROXY_STEP_HLS_STATUS: DONE (renderedFrames=$hlsRenderedFrames, bytesRead=$hlsCacheBytesRead, state=${finalHlsStatus.state.name}, dims=${finalHlsStatus.effectiveDisplayWidth}x${finalHlsStatus.effectiveDisplayHeight})',
        );
      } finally {
        // Guaranteed cleanup for HLS session
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_STEP_HLS_DISPOSE: START');
        if (hlsSession.textureId >= 0) {
          await _client.dispose(hlsSession).timeout(_kControlTimeout);
        }
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_STEP_HLS_DISPOSE: DONE');
        if (mounted) {
          setState(() {
            _textureId = null;
          });
        }
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Case 2: LL-HLS Proxy Pass-Through Playback
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_STEP_LL_HLS_OPEN: START');
      if (mounted) {
        setState(() {
          _status = 'Opening LL-HLS stream with local proxy cache enabled…';
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
              cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
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
        'IOS_STREAMING_LOCAL_PROXY_STEP_LL_HLS_OPEN: DONE (textureId=${llSession.textureId})',
      );

      if (mounted) {
        setState(() {
          _textureId = llSession.textureId;
          _status =
              'LL-HLS proxy streaming active (textureId=${llSession.textureId})…';
        });
      }

      try {
        // Poll status until frames render and cache telemetry is confirmed
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_STEP_LL_HLS_STATUS: START');
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
              status.state != VGStreamingPlaybackState.unsupported &&
              status.playbackCacheEnabled == true &&
              status.playbackCacheTelemetryAttached == true &&
              status.playbackCacheIgnoredCount == 0 &&
              status.playbackCacheBytesRead > 0) {
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
            'LL-HLS proxy pass-through verification timed out: '
            'renderedFrames=${lastStatus.renderedFrames}, '
            'state=${lastStatus.state.name}, '
            'effectiveDisplayWidth=${lastStatus.effectiveDisplayWidth}, '
            'effectiveDisplayHeight=${lastStatus.effectiveDisplayHeight}, '
            'playbackCacheEnabled=${lastStatus.playbackCacheEnabled}, '
            'playbackCacheTelemetryAttached=${lastStatus.playbackCacheTelemetryAttached}, '
            'playbackCacheIgnoredCount=${lastStatus.playbackCacheIgnoredCount}, '
            'playbackCacheBytesRead=${lastStatus.playbackCacheBytesRead}, '
            'raw=${lastStatus.raw}',
          );
        }

        llHlsRenderedFrames = finalLlStatus.renderedFrames;
        llHlsCacheBytesRead = finalLlStatus.playbackCacheBytesRead;
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
          'playbackCacheEnabled': finalLlStatus.playbackCacheEnabled,
          'playbackCacheTelemetryAttached':
              finalLlStatus.playbackCacheTelemetryAttached,
          'playbackCacheBytesRead': finalLlStatus.playbackCacheBytesRead,
          'playbackCacheSizeBytes': finalLlStatus.playbackCacheSizeBytes,
          'playbackCacheIgnoredCount': finalLlStatus.playbackCacheIgnoredCount,
          'playbackCacheLastIgnoredReason':
              finalLlStatus.playbackCacheLastIgnoredReason,
          'raw': finalLlStatus.raw,
        };

        // ignore: avoid_print
        print(
          'IOS_STREAMING_LOCAL_PROXY_STEP_LL_HLS_STATUS: DONE (renderedFrames=$llHlsRenderedFrames, bytesRead=$llHlsCacheBytesRead, state=${finalLlStatus.state.name}, dims=${finalLlStatus.effectiveDisplayWidth}x${finalLlStatus.effectiveDisplayHeight})',
        );
      } finally {
        // Guaranteed cleanup for LL-HLS session
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_STEP_LL_HLS_DISPOSE: START');
        if (llSession.textureId >= 0) {
          await _client.dispose(llSession).timeout(_kControlTimeout);
        }
        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_STEP_LL_HLS_DISPOSE: DONE');
        if (mounted) {
          setState(() {
            _textureId = null;
          });
        }
      }

      // ═══════════════════════════════════════════════════════════════════════
      // Case 3: DASH Typed Deferral Verification with Cache Enabled
      // ═══════════════════════════════════════════════════════════════════════
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_STEP_DASH_UNSUPPORTED: START');
      if (mounted) {
        setState(() {
          _status = 'Testing DASH typed deferral with cache enabled…';
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
              cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
            ),
          )
          .timeout(_kOperationTimeout);

      try {
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
          'playbackCacheEnabled': dashSession.playbackCacheEnabled,
          'playbackCacheTelemetryAttached':
              dashSession.playbackCacheTelemetryAttached,
          'playbackCacheBytesRead': dashSession.playbackCacheBytesRead,
          'playbackCacheSizeBytes': dashSession.playbackCacheSizeBytes,
          'playbackCacheIgnoredCount': dashSession.playbackCacheIgnoredCount,
          'raw': dashSession.raw,
          'proxiedPlayback': false,
        };

        // ignore: avoid_print
        print('IOS_STREAMING_LOCAL_PROXY_STEP_DASH_UNSUPPORTED: DONE');
      } finally {
        if (dashSession.textureId >= 0) {
          await _client.dispose(dashSession).timeout(_kControlTimeout);
        }
      }

      allPass = true;
      results['pass'] = true;
      results['hlsPass'] = true;
      results['llHlsPass'] = true;
      results['dashPass'] = true;
      results['hlsRenderedFrames'] = hlsRenderedFrames;
      results['hlsCacheBytesRead'] = hlsCacheBytesRead;
      results['llHlsRenderedFrames'] = llHlsRenderedFrames;
      results['llHlsCacheBytesRead'] = llHlsCacheBytesRead;
      results['dashRaw'] = dashRaw;
    } catch (error, stack) {
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_PHYSICAL_ERROR: $error\n$stack');
      results['pass'] = false;
      results['error'] = error.toString();
      allPass = false;
    }

    // Emit terminal JSON line
    // ignore: avoid_print
    print(
      'IOS_STREAMING_LOCAL_PROXY_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(results)}',
    );

    // Emit terminal marker
    if (allPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_PUBLIC_API_PHYSICAL_PASS');
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_LOCAL_PROXY_PUBLIC_API_PHYSICAL_FAIL');
    }

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS (HLS: $hlsRenderedFrames frames, $hlsCacheBytesRead cache bytes; LL-HLS: $llHlsRenderedFrames frames, $llHlsCacheBytesRead cache bytes; DASH: unsupported deferred)'
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
