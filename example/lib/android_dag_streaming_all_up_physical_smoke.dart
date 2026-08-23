// Vanguard Android True-DAG Phase 4C1D1F: Physical streaming all-up smoke test.
//
// Sequentially verifies the Media3 -> ImageReader/HardwareBuffer -> Vanguard DAG -> SurfaceProducer
// path across all three streaming formats:
//   1. HLS (Mux public test stream)
//   2. DASH (Shaka demo Angel One stream)
//   3. LL-HLS (Mux public low-latency stream)
// Phase 4C5B: NETWORK_PROFILE dart-define selects the streaming network policy for this smoke.
//   Default is CONSTRAINED (poor-network policy). Override with --dart-define=NETWORK_PROFILE=AUTO
//   to use Media3 defaults.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
const String _networkProfile = String.fromEnvironment(
  'NETWORK_PROFILE',
  defaultValue: 'CONSTRAINED',
);

class _StreamTestCase {
  final String key;
  final String name;
  final String uri;
  final String formatHint;

  const _StreamTestCase({
    required this.key,
    required this.name,
    required this.uri,
    required this.formatHint,
  });
}

const List<_StreamTestCase> _testCases = [
  _StreamTestCase(
    key: 'hls',
    name: 'HLS',
    uri: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    formatHint: 'HLS',
  ),
  _StreamTestCase(
    key: 'dash',
    name: 'DASH',
    uri: 'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
    formatHint: 'DASH',
  ),
  _StreamTestCase(
    key: 'llHls',
    name: 'LL-HLS',
    uri:
        'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
    formatHint: 'HLS',
  ),
];

void main() {
  runApp(const AndroidDagStreamingAllUpPhysicalSmokeApp());
}

class AndroidDagStreamingAllUpPhysicalSmokeApp extends StatefulWidget {
  const AndroidDagStreamingAllUpPhysicalSmokeApp({super.key});

  @override
  State<AndroidDagStreamingAllUpPhysicalSmokeApp> createState() =>
      _AndroidDagStreamingAllUpPhysicalSmokeAppState();
}

class _AndroidDagStreamingAllUpPhysicalSmokeAppState
    extends State<AndroidDagStreamingAllUpPhysicalSmokeApp> {
  static const MethodChannel _channel = MethodChannel('vanguard_media_engine');
  String _status = 'Initializing Android DAG streaming all-up physical smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runAllUpSmoke();
    });
  }

  Future<void> _runAllUpSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    final results = <String, dynamic>{};
    bool allPass = true;

    for (final testCase in _testCases) {
      int? activeTextureId;
      Map<String, dynamic> diagMap = <String, dynamic>{};
      bool casePass = false;
      int renderedFrames = 0;
      String state = '';
      bool surfaceLost = false;

      try {
        if (mounted) {
          setState(() {
            _textureId = null;
            _status =
                'Starting ${testCase.name} playback (${testCase.formatHint})…';
          });
        }

        // 1. Create streaming playback session with autoPlay true
        final createResponse = await _channel.invokeMethod<Object?>(
          'createAndroidDagPhase4C1D1StreamingPlayback',
          <String, Object>{
            'uri': testCase.uri,
            'formatHint': testCase.formatHint,
            'initialWidth': _initialWidth,
            'initialHeight': _initialHeight,
            'autoPlay': true,
            // Phase 4C5B: forward the smoke-run network profile to Android.
            'networkProfile': _networkProfile,
          },
        );

        if (createResponse == null || createResponse is! Map) {
          throw Exception(
            'createAndroidDagPhase4C1D1StreamingPlayback returned invalid response: $createResponse',
          );
        }

        final createMap = Map<String, dynamic>.from(createResponse);
        final createPass = createMap['pass'] == true;
        activeTextureId = (createMap['textureId'] as num?)?.toInt();
        diagMap = createMap;

        if (!createPass || activeTextureId == null || activeTextureId < 0) {
          throw Exception(
            'Create ${testCase.name} playback failed: ${createMap['raw']} (textureId: $activeTextureId)',
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

        // 4. Diagnose playback state
        final diagResponse = await _channel.invokeMethod<Object?>(
          'diagnoseAndroidDagPhase4C1D1StreamingPlayback',
          <String, Object>{'textureId': activeTextureId},
        );

        if (diagResponse != null && diagResponse is Map) {
          diagMap = Map<String, dynamic>.from(diagResponse);
        } else {
          diagMap = <String, dynamic>{
            'pass': false,
            'raw': 'status=FAIL;reason=diagnose_null_response',
            'renderedFrames': 0,
          };
        }

        renderedFrames = (diagMap['renderedFrames'] as num?)?.toInt() ?? 0;
        final diagPass = diagMap['pass'] != false;
        surfaceLost = diagMap['surfaceLost'] == true;
        state = diagMap['state'] as String? ?? '';

        // Phase 4C4L: Read adaptive timeline telemetry fields.
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

        // Phase 4C4L: Validate timeline telemetry per-case.
        // Timeline assertions are diagnostic-only and are added on top of existing pass criteria.
        bool timelinePass = true;
        if (!adaptiveTimelineAttached) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_DAG_STREAMING_ALL_UP_${testCase.key.toUpperCase()}_TIMELINE_FAIL: adaptiveTimelineAttached=false',
          );
        }
        if (!adaptiveTimelineStarted) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_DAG_STREAMING_ALL_UP_${testCase.key.toUpperCase()}_TIMELINE_FAIL: adaptiveTimelineStarted=false',
          );
        }
        if (adaptiveTimelineAcceptedFrames <= 0) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_DAG_STREAMING_ALL_UP_${testCase.key.toUpperCase()}_TIMELINE_FAIL: adaptiveTimelineAcceptedFrames=$adaptiveTimelineAcceptedFrames',
          );
        }
        // acceptedFrames must not exceed renderedFrames + 1 (one-frame lead is allowed because timeline evaluation occurs immediately before native render counting)
        if (adaptiveTimelineAcceptedFrames > renderedFrames + 1) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_DAG_STREAMING_ALL_UP_${testCase.key.toUpperCase()}_TIMELINE_FAIL: acceptedFrames($adaptiveTimelineAcceptedFrames) > renderedFrames($renderedFrames) + 1 (one-frame lead is allowed because timeline evaluation occurs immediately before native render counting)',
          );
        }
        if (renderedFrames > 0 && adaptiveTimelineLastAcceptedPtsUs == null) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_DAG_STREAMING_ALL_UP_${testCase.key.toUpperCase()}_TIMELINE_FAIL: lastAcceptedPtsUs=null when renderedFrames=$renderedFrames',
          );
        }
        if (renderedFrames > 0 &&
            adaptiveTimelineLastAcceptedFrameIndex == null) {
          timelinePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_DAG_STREAMING_ALL_UP_${testCase.key.toUpperCase()}_TIMELINE_FAIL: lastAcceptedFrameIndex=null when renderedFrames=$renderedFrames',
          );
        }

        // Phase 4C5B: Assert that the reported streamingNetworkProfile matches
        // the profile we passed into create. Diagnostic-only assertion that
        // does not alter existing frame/state pass criteria.
        final reportedNetworkProfile =
            diagMap['streamingNetworkProfile'] as String?;
        bool networkProfilePass = true;
        if (reportedNetworkProfile == null) {
          networkProfilePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_DAG_STREAMING_ALL_UP_${testCase.key.toUpperCase()}_NETWORK_PROFILE_FAIL:'
            ' streamingNetworkProfile=null (expected $_networkProfile)',
          );
        } else if (reportedNetworkProfile != _networkProfile) {
          networkProfilePass = false;
          // ignore: avoid_print
          print(
            'ANDROID_DAG_STREAMING_ALL_UP_${testCase.key.toUpperCase()}_NETWORK_PROFILE_FAIL:'
            ' streamingNetworkProfile=$reportedNetworkProfile (expected $_networkProfile)',
          );
        }

        // 5. Pass only if renderedFrames > 0, pass != false, surfaceLost != true, state != Failed,
        //    all timeline assertions pass, and network profile reported correctly.
        casePass = renderedFrames > 0 &&
            diagPass &&
            !surfaceLost &&
            state != 'Failed' &&
            timelinePass &&
            networkProfilePass;
      } catch (error, stack) {
        // ignore: avoid_print
        print(
          'ANDROID_DAG_STREAMING_ALL_UP_${testCase.key.toUpperCase()}_ERROR: $error\n$stack',
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
        // 6. Always dispose if textureId exists, even on failure
        if (activeTextureId != null && activeTextureId >= 0) {
          try {
            await _channel.invokeMethod<Object?>(
              'disposeAndroidDagPhase4C1D1StreamingPlayback',
              <String, Object>{'textureId': activeTextureId},
            );
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
        'state': state,
        'surfaceLost': surfaceLost,
        'adaptiveTimelineAttached': diagMap['adaptiveTimelineAttached'],
        'adaptiveTimelineStarted': diagMap['adaptiveTimelineStarted'],
        'adaptiveTimelineAcceptedFrames':
            diagMap['adaptiveTimelineAcceptedFrames'],
        'adaptiveTimelineLastAcceptedPtsUs':
            diagMap['adaptiveTimelineLastAcceptedPtsUs'],
        'adaptiveTimelineLastAcceptedFrameIndex':
            diagMap['adaptiveTimelineLastAcceptedFrameIndex'],
        // Phase 4C5B: per-case network profile field.
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
      'hlsRaw': results['hls']?['raw'] ?? '',
      'dashRaw': results['dash']?['raw'] ?? '',
      'llHlsRaw': results['llHls']?['raw'] ?? '',
      // Phase 4C4L: Adaptive timeline telemetry per protocol.
      'hlsAdaptiveTimelineStarted':
          results['hls']?['adaptiveTimelineStarted'],
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
      // Phase 4C5B: per-protocol streaming network profile fields.
      'networkProfileUsed': _networkProfile,
      'hlsStreamingNetworkProfile':
          results['hls']?['streamingNetworkProfile'],
      'dashStreamingNetworkProfile':
          results['dash']?['streamingNetworkProfile'],
      'llHlsStreamingNetworkProfile':
          results['llHls']?['streamingNetworkProfile'],
      'cases': results,
    };

    // Print aggregated JSON and terminal pass/fail marker
    // ignore: avoid_print
    print(
      'ANDROID_DAG_STREAMING_ALL_UP_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_DAG_STREAMING_ALL_UP_PHYSICAL_PASS'
          : 'ANDROID_DAG_STREAMING_ALL_UP_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: All 3 streaming formats verified (HLS: ${results['hls']?['renderedFrames']}f, DASH: ${results['dash']?['renderedFrames']}f, LL-HLS: ${results['llHls']?['renderedFrames']}f)'
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
