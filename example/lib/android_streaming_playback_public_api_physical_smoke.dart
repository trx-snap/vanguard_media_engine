// Vanguard Android True-DAG Phase 4C7C: Public streaming playback API physical smoke test.
//
// Sequentially verifies the Media3 -> ImageReader/HardwareBuffer -> Vanguard DAG -> SurfaceProducer
// path across all three streaming formats using the public VGStreamingPlaybackClient API:
//   1. HLS (Mux public test stream)
//   2. DASH (Shaka demo Angel One stream)
//   3. LL-HLS (Mux public low-latency stream)
// NETWORK_PROFILE dart-define selects the streaming network policy for this smoke.
//   Default is CONSTRAINED (poor-network policy). Override with --dart-define=NETWORK_PROFILE=AUTO
//   to use Media3 defaults.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

const int _initialWidth = int.fromEnvironment(
  'INITIAL_WIDTH',
  defaultValue: 640,
);

const int _initialHeight = int.fromEnvironment(
  'INITIAL_HEIGHT',
  defaultValue: 360,
);

const int _waitSeconds = int.fromEnvironment('WAIT_SECONDS', defaultValue: 12);

/// Streaming network profile to apply for every session in this smoke run.
/// Defaults to CONSTRAINED (poor-network conservative policy).
/// Override at build time: --dart-define=NETWORK_PROFILE=AUTO|STABLE|CONSTRAINED|LOW_LATENCY
const String _networkProfileString = String.fromEnvironment(
  'NETWORK_PROFILE',
  defaultValue: 'CONSTRAINED',
);

final VGStreamingNetworkProfile _networkProfile =
    VGStreamingNetworkProfile.fromString(_networkProfileString);

class _StreamTestCase {
  final String key;
  final String name;
  final Uri uri;
  final VGStreamingFormatHint formatHint;

  const _StreamTestCase({
    required this.key,
    required this.name,
    required this.uri,
    required this.formatHint,
  });
}

final List<_StreamTestCase> _testCases = [
  _StreamTestCase(
    key: 'hls',
    name: 'HLS',
    uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
    formatHint: VGStreamingFormatHint.hls,
  ),
  _StreamTestCase(
    key: 'dash',
    name: 'DASH',
    uri: Uri.parse(
      'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
    ),
    formatHint: VGStreamingFormatHint.dash,
  ),
  _StreamTestCase(
    key: 'llHls',
    name: 'LL-HLS',
    uri: Uri.parse(
      'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
    ),
    formatHint: VGStreamingFormatHint.hls,
  ),
];

void main() {
  runApp(const AndroidStreamingPlaybackPublicApiPhysicalSmokeApp());
}

class AndroidStreamingPlaybackPublicApiPhysicalSmokeApp extends StatefulWidget {
  const AndroidStreamingPlaybackPublicApiPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingPlaybackPublicApiPhysicalSmokeApp> createState() =>
      _AndroidStreamingPlaybackPublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingPlaybackPublicApiPhysicalSmokeAppState
    extends State<AndroidStreamingPlaybackPublicApiPhysicalSmokeApp> {
  final VGStreamingPlaybackClient _client = VGStreamingPlaybackClient();
  String _status =
      'Initializing Android streaming playback public API physical smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runPublicApiSmoke();
    });
  }

  Future<void> _runPublicApiSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    final results = <String, dynamic>{};
    bool allPass = true;

    for (final testCase in _testCases) {
      VGStreamingPlaybackSession? session;
      Map<String, dynamic> diagMap = <String, dynamic>{};
      bool casePass = false;
      int renderedFrames = 0;
      String stateStr = '';
      bool surfaceLost = false;
      int rotationDegrees = 0;
      int displayWidth = 0;
      int displayHeight = 0;
      int effectiveDisplayWidth = 0;
      int effectiveDisplayHeight = 0;
      int videoWidth = 0;
      int videoHeight = 0;
      int rawWidth = 0;
      int rawHeight = 0;
      bool orientationMetadataPass = false;
      int durationMs = -1;
      int positionMs = 0;
      int bufferedPositionMs = 0;
      int bufferedPercent = 0;
      int? liveOffsetMs;
      bool timingBufferPass = false;

      try {
        if (mounted) {
          setState(() {
            _textureId = null;
            _status =
                'Starting ${testCase.name} playback (${testCase.formatHint.name})…';
          });
        }

        // 1. Open streaming playback session using public client API with autoPlay: true
        session = await _client.open(
          VGStreamingPlaybackOptions(
            uri: testCase.uri,
            initialWidth: _initialWidth,
            initialHeight: _initialHeight,
            formatHint: testCase.formatHint,
            networkProfile: _networkProfile,
            autoPlay: true,
          ),
        );

        diagMap = Map<String, dynamic>.from(session.diagnostics);
        final activeTextureId = session.textureId;

        if (!session.pass || activeTextureId < 0) {
          throw Exception(
            'Open ${testCase.name} playback failed: ${session.raw} (textureId: $activeTextureId)',
          );
        }

        // 2. Show active texture while waiting
        if (mounted) {
          setState(() {
            _textureId = activeTextureId;
            _status =
                '${testCase.name} streaming active (textureId=$activeTextureId), waiting ${_waitSeconds}s…';
          });
        }

        // 3. Wait WAIT_SECONDS
        await Future<void>.delayed(Duration(seconds: _waitSeconds));

        // 4. Retrieve latest status via public client getStatus
        final status = await _client.getStatus(session);
        diagMap = Map<String, dynamic>.from(status.diagnostics);

        renderedFrames = status.renderedFrames;
        final statusPass = status.pass != false;
        surfaceLost =
            status.state == VGStreamingPlaybackState.surfaceLost ||
            diagMap['surfaceLost'] == true;
        final isFailed = status.state == VGStreamingPlaybackState.failed;
        stateStr = status.state.name;

        // Adaptive timeline telemetry fields
        final adaptiveTimelineAttached =
            diagMap['adaptiveTimelineAttached'] == true;
        final adaptiveTimelineStarted =
            diagMap['adaptiveTimelineStarted'] == true;
        final adaptiveTimelineAcceptedFrames =
            (diagMap['adaptiveTimelineAcceptedFrames'] as num?)?.toInt() ?? 0;
        final adaptiveTimelineLastAcceptedPtsUs =
            diagMap['adaptiveTimelineLastAcceptedPtsUs'];
        final adaptiveTimelineLastAcceptedFrameIndex =
            diagMap['adaptiveTimelineLastAcceptedFrameIndex'];

        // Timeline assertions
        bool timelinePass = true;
        if (!adaptiveTimelineAttached) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMELINE_FAIL: adaptiveTimelineAttached=false',
          );
        }
        if (!adaptiveTimelineStarted) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMELINE_FAIL: adaptiveTimelineStarted=false',
          );
        }
        if (adaptiveTimelineAcceptedFrames <= 0) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMELINE_FAIL: adaptiveTimelineAcceptedFrames=$adaptiveTimelineAcceptedFrames',
          );
        }
        if (adaptiveTimelineAcceptedFrames > renderedFrames + 1) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMELINE_FAIL: acceptedFrames($adaptiveTimelineAcceptedFrames) > renderedFrames($renderedFrames) + 1',
          );
        }
        if (renderedFrames > 0 && adaptiveTimelineLastAcceptedPtsUs == null) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMELINE_FAIL: lastAcceptedPtsUs=null when renderedFrames=$renderedFrames',
          );
        }
        if (renderedFrames > 0 &&
            adaptiveTimelineLastAcceptedFrameIndex == null) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMELINE_FAIL: lastAcceptedFrameIndex=null when renderedFrames=$renderedFrames',
          );
        }

        // Network profile assertion
        final reportedNetworkProfile =
            diagMap['streamingNetworkProfile'] as String?;
        final expectedNetworkProfile = _networkProfile.toNative();
        bool networkProfilePass = true;
        if (reportedNetworkProfile == null) {
          networkProfilePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_NETWORK_PROFILE_FAIL:'
            ' streamingNetworkProfile=null (expected $expectedNetworkProfile)',
          );
        } else if (reportedNetworkProfile != expectedNetworkProfile) {
          networkProfilePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_NETWORK_PROFILE_FAIL:'
            ' streamingNetworkProfile=$reportedNetworkProfile (expected $expectedNetworkProfile)',
          );
        }

        // Orientation & display dimension telemetry assertions (Phases 4C7U/4C7V)
        rotationDegrees = status.rotationDegrees;
        displayWidth = status.displayWidth;
        displayHeight = status.displayHeight;
        effectiveDisplayWidth = status.effectiveDisplayWidth;
        effectiveDisplayHeight = status.effectiveDisplayHeight;
        videoWidth = status.videoWidth;
        videoHeight = status.videoHeight;
        rawWidth = (diagMap['width'] as num?)?.toInt() ?? 0;
        rawHeight = (diagMap['height'] as num?)?.toInt() ?? 0;
        final rawVideoWidth = (diagMap['videoWidth'] as num?)?.toInt() ?? 0;
        final rawVideoHeight = (diagMap['videoHeight'] as num?)?.toInt() ?? 0;

        final hasRotationKey = diagMap.containsKey('rotationDegrees');
        final hasDisplayWidthKey = diagMap.containsKey('displayWidth');
        final hasDisplayHeightKey = diagMap.containsKey('displayHeight');
        final hasWidthKey = diagMap.containsKey('width');
        final hasHeightKey = diagMap.containsKey('height');
        final hasVideoWidthKey = diagMap.containsKey('videoWidth');
        final hasVideoHeightKey = diagMap.containsKey('videoHeight');

        final validRotation =
            rotationDegrees == 0 ||
            rotationDegrees == 90 ||
            rotationDegrees == 180 ||
            rotationDegrees == 270;
        final positiveDisplayDimensions =
            effectiveDisplayWidth > 0 && effectiveDisplayHeight > 0;
        final positiveEncodedDimensions =
            videoWidth > 0 &&
            videoHeight > 0 &&
            rawVideoWidth > 0 &&
            rawVideoHeight > 0;
        final canvasDimensionsMatchDisplay =
            rawWidth > 0 &&
            rawHeight > 0 &&
            rawWidth == effectiveDisplayWidth &&
            rawHeight == effectiveDisplayHeight;

        orientationMetadataPass = true;
        if (!hasRotationKey ||
            !hasDisplayWidthKey ||
            !hasDisplayHeightKey ||
            !hasWidthKey ||
            !hasHeightKey ||
            !hasVideoWidthKey ||
            !hasVideoHeightKey) {
          orientationMetadataPass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_ORIENTATION_FAIL:'
            ' missing orientation/display keys (rotationDegrees=$hasRotationKey, displayWidth=$hasDisplayWidthKey, displayHeight=$hasDisplayHeightKey, width=$hasWidthKey, height=$hasHeightKey, videoWidth=$hasVideoWidthKey, videoHeight=$hasVideoHeightKey)',
          );
        }
        if (!validRotation) {
          orientationMetadataPass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_ORIENTATION_FAIL:'
            ' invalid rotationDegrees=$rotationDegrees',
          );
        }
        if (!positiveDisplayDimensions) {
          orientationMetadataPass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_ORIENTATION_FAIL:'
            ' non-positive effective display dimensions (${effectiveDisplayWidth}x$effectiveDisplayHeight)',
          );
        }
        if (!positiveEncodedDimensions) {
          orientationMetadataPass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_ORIENTATION_FAIL:'
            ' non-positive encoded dimensions (videoWidth=$videoWidth, videoHeight=$videoHeight, rawVideoWidth=$rawVideoWidth, rawVideoHeight=$rawVideoHeight)',
          );
        }
        if (!canvasDimensionsMatchDisplay) {
          orientationMetadataPass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_ORIENTATION_FAIL:'
            ' canvas dimensions do not match display dimensions (canvas=${rawWidth}x$rawHeight, display=${effectiveDisplayWidth}x$effectiveDisplayHeight)',
          );
        }

        // Timing and buffer telemetry assertions (Phases 4C7W/4C7X)
        durationMs = status.durationMs;
        positionMs = status.positionMs;
        bufferedPositionMs = status.bufferedPositionMs;
        bufferedPercent = status.bufferedPercent;
        liveOffsetMs = status.liveOffsetMs;

        final hasDurationKey = diagMap.containsKey('durationMs');
        final hasPositionKey = diagMap.containsKey('positionMs');
        final hasBufferedPositionKey = diagMap.containsKey(
          'bufferedPositionMs',
        );
        final hasBufferedPercentKey = diagMap.containsKey('bufferedPercent');
        final hasLiveOffsetKey = diagMap.containsKey('liveOffsetMs');

        timingBufferPass = true;
        if (!hasDurationKey ||
            !hasPositionKey ||
            !hasBufferedPositionKey ||
            !hasBufferedPercentKey ||
            !hasLiveOffsetKey) {
          timingBufferPass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMING_BUFFER_FAIL:'
            ' missing timing/buffer keys (durationMs=$hasDurationKey, positionMs=$hasPositionKey, bufferedPositionMs=$hasBufferedPositionKey, bufferedPercent=$hasBufferedPercentKey, liveOffsetMs=$hasLiveOffsetKey)',
          );
        }
        if (durationMs < -1) {
          timingBufferPass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMING_BUFFER_FAIL:'
            ' invalid durationMs=$durationMs (< -1)',
          );
        }
        if (positionMs < 0) {
          timingBufferPass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMING_BUFFER_FAIL:'
            ' invalid positionMs=$positionMs (< 0)',
          );
        }
        if (bufferedPositionMs < 0) {
          timingBufferPass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMING_BUFFER_FAIL:'
            ' invalid bufferedPositionMs=$bufferedPositionMs (< 0)',
          );
        }
        if (bufferedPercent < 0 || bufferedPercent > 100) {
          timingBufferPass = false;
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_TIMING_BUFFER_FAIL:'
            ' invalid bufferedPercent=$bufferedPercent (not in 0..100)',
          );
        }

        // 5. Assert pass criteria
        casePass =
            statusPass &&
            renderedFrames > 0 &&
            !surfaceLost &&
            !isFailed &&
            timelinePass &&
            networkProfilePass &&
            orientationMetadataPass &&
            timingBufferPass;
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_ERROR: $error\n$stack',
        );
        if (diagMap.isEmpty) {
          diagMap = <String, dynamic>{
            'pass': false,
            'raw': 'status=FAIL;reason=dart_exception:$error',
            'renderedFrames': 0,
          };
        }
        casePass = false;
      } finally {
        // 6. Always dispose via public client if session exists with valid textureId
        if (session != null && session.textureId >= 0) {
          try {
            await _client.dispose(session);
          } catch (e) {
            // ignore: avoid_print
            print('Dispose error for ${testCase.name}: $e');
          }
        }
      }

      if (!casePass) {
        allPass = false;
      }

      results[testCase.key] = <String, dynamic>{
        'pass': casePass,
        'renderedFrames': renderedFrames,
        'state': stateStr,
        'surfaceLost': surfaceLost,
        'durationMs': durationMs,
        'positionMs': positionMs,
        'bufferedPositionMs': bufferedPositionMs,
        'bufferedPercent': bufferedPercent,
        'liveOffsetMs': liveOffsetMs,
        'timingBufferPass': timingBufferPass,
        'rotationDegrees': rotationDegrees,
        'displayWidth': displayWidth,
        'displayHeight': displayHeight,
        'effectiveDisplayWidth': effectiveDisplayWidth,
        'effectiveDisplayHeight': effectiveDisplayHeight,
        'videoWidth': videoWidth,
        'videoHeight': videoHeight,
        'width': rawWidth,
        'height': rawHeight,
        'orientationMetadataPass': orientationMetadataPass,
        'adaptiveTimelineAttached': diagMap['adaptiveTimelineAttached'],
        'adaptiveTimelineStarted': diagMap['adaptiveTimelineStarted'],
        'adaptiveTimelineAcceptedFrames':
            diagMap['adaptiveTimelineAcceptedFrames'],
        'adaptiveTimelineLastAcceptedPtsUs':
            diagMap['adaptiveTimelineLastAcceptedPtsUs'],
        'adaptiveTimelineLastAcceptedFrameIndex':
            diagMap['adaptiveTimelineLastAcceptedFrameIndex'],
        'streamingNetworkProfile': diagMap['streamingNetworkProfile'],
        'raw':
            diagMap['raw']?.toString() ??
            (casePass ? 'status=OK' : 'status=FAIL'),
        'details': diagMap,
      };

      if (mounted) {
        setState(() {
          _textureId = null;
          _status =
              '${testCase.name}: ${casePass ? "PASS ($renderedFrames frames)" : "FAIL (${diagMap['raw']})"}.';
        });
      }

      // Short delay between stream test cases
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    final hlsPass = results['hls']?['pass'] == true;
    final dashPass = results['dash']?['pass'] == true;
    final llHlsPass = results['llHls']?['pass'] == true;

    final aggregatedMap = <String, dynamic>{
      'pass': allPass,
      'hlsPass': hlsPass,
      'dashPass': dashPass,
      'llHlsPass': llHlsPass,
      'hlsRenderedFrames': results['hls']?['renderedFrames'] ?? 0,
      'dashRenderedFrames': results['dash']?['renderedFrames'] ?? 0,
      'llHlsRenderedFrames': results['llHls']?['renderedFrames'] ?? 0,
      'hlsDurationMs': results['hls']?['durationMs'],
      'hlsPositionMs': results['hls']?['positionMs'],
      'hlsBufferedPercent': results['hls']?['bufferedPercent'],
      'hlsBufferedPositionMs': results['hls']?['bufferedPositionMs'],
      'dashDurationMs': results['dash']?['durationMs'],
      'dashPositionMs': results['dash']?['positionMs'],
      'dashBufferedPercent': results['dash']?['bufferedPercent'],
      'dashBufferedPositionMs': results['dash']?['bufferedPositionMs'],
      'llHlsDurationMs': results['llHls']?['durationMs'],
      'llHlsPositionMs': results['llHls']?['positionMs'],
      'llHlsBufferedPercent': results['llHls']?['bufferedPercent'],
      'llHlsBufferedPositionMs': results['llHls']?['bufferedPositionMs'],
      'hlsRotationDegrees': results['hls']?['rotationDegrees'] ?? 0,
      'dashRotationDegrees': results['dash']?['rotationDegrees'] ?? 0,
      'llHlsRotationDegrees': results['llHls']?['rotationDegrees'] ?? 0,
      'hlsEffectiveDisplayWidth': results['hls']?['effectiveDisplayWidth'] ?? 0,
      'hlsEffectiveDisplayHeight':
          results['hls']?['effectiveDisplayHeight'] ?? 0,
      'dashEffectiveDisplayWidth':
          results['dash']?['effectiveDisplayWidth'] ?? 0,
      'dashEffectiveDisplayHeight':
          results['dash']?['effectiveDisplayHeight'] ?? 0,
      'llHlsEffectiveDisplayWidth':
          results['llHls']?['effectiveDisplayWidth'] ?? 0,
      'llHlsEffectiveDisplayHeight':
          results['llHls']?['effectiveDisplayHeight'] ?? 0,
      'hlsRaw': results['hls']?['raw'] ?? '',
      'dashRaw': results['dash']?['raw'] ?? '',
      'llHlsRaw': results['llHls']?['raw'] ?? '',
      'hlsAdaptiveTimelineStarted': results['hls']?['adaptiveTimelineStarted'],
      'dashAdaptiveTimelineStarted':
          results['dash']?['adaptiveTimelineStarted'],
      'llHlsAdaptiveTimelineStarted':
          results['llHls']?['adaptiveTimelineStarted'],
      'hlsAdaptiveTimelineAcceptedFrames':
          results['hls']?['adaptiveTimelineAcceptedFrames'],
      'dashAdaptiveTimelineAcceptedFrames':
          results['dash']?['adaptiveTimelineAcceptedFrames'],
      'llHlsAdaptiveTimelineAcceptedFrames':
          results['llHls']?['adaptiveTimelineAcceptedFrames'],
      'networkProfileUsed': _networkProfile.toNative(),
      'hlsStreamingNetworkProfile': results['hls']?['streamingNetworkProfile'],
      'dashStreamingNetworkProfile':
          results['dash']?['streamingNetworkProfile'],
      'llHlsStreamingNetworkProfile':
          results['llHls']?['streamingNetworkProfile'],
      'cases': results,
    };

    // Print aggregated JSON and terminal pass/fail marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_PLAYBACK_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: All 3 streaming formats verified via public API (HLS: ${results['hls']?['renderedFrames']}f, DASH: ${results['dash']?['renderedFrames']}f, LL-HLS: ${results['llHls']?['renderedFrames']}f)'
            : 'FAIL: (HLS: $hlsPass, DASH: $dashPass, LL-HLS: $llHlsPass)';
      });
    }

    // Exit process after short delay so flutter run finishes unattended
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
