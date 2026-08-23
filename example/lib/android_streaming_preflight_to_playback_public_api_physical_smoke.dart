// Vanguard Android True-DAG Phase 4C7H: Public preflight -> startup plan -> playback all-up physical smoke.
//
// Sequentially verifies:
//   1. Public preflight evaluation across HLS, DASH, and LL-HLS manifests under CONSTRAINED network profile.
//   2. Startup plan synthesis from preflight advisory report.
//   3. Playback options construction from the startup plan.
//   4. Adaptive streaming playback execution across all three formats:
//      - HLS (Mux public test stream)
//      - DASH (Shaka demo Angel One stream)
//      - LL-HLS (Mux public low-latency stream)
//
// Verification Invariants & Boundaries:
// - Imports ONLY package:vanguard_media_engine/vanguard_media_engine.dart.
// - No direct MethodChannel or services.dart imports.
// - Uses:
//     VGStreamingPreflightClient.evaluate(...)
//     VGStreamingStartupPlanner.fromPreflight(...)
//     VGStreamingStartupPlan.buildPlaybackOptions(...)
//     VGStreamingPlaybackClient.open/play/pause/seek/getStatus/stop/dispose
// - Pure advisory validation before playback: advisoryOnly == true, playbackMutation == false.
// - Physical pass requires preflight pass, plan.shouldProceed == true, and positive rendered frame counts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

class _StreamTestCase {
  final String key;
  final String name;
  final Uri uri;
  final VGStreamingFormatHint formatHint;
  final bool isVod;

  const _StreamTestCase({
    required this.key,
    required this.name,
    required this.uri,
    required this.formatHint,
    required this.isVod,
  });
}

final List<_StreamTestCase> _testCases = [
  _StreamTestCase(
    key: 'hls',
    name: 'HLS',
    uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
    formatHint: VGStreamingFormatHint.hls,
    isVod: true,
  ),
  _StreamTestCase(
    key: 'dash',
    name: 'DASH',
    uri: Uri.parse(
      'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
    ),
    formatHint: VGStreamingFormatHint.dash,
    isVod: true,
  ),
  _StreamTestCase(
    key: 'llHls',
    name: 'LL-HLS',
    uri: Uri.parse(
      'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
    ),
    formatHint: VGStreamingFormatHint.hls,
    isVod: false,
  ),
];

void main() {
  runApp(const AndroidStreamingPreflightToPlaybackPublicApiPhysicalSmokeApp());
}

class AndroidStreamingPreflightToPlaybackPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingPreflightToPlaybackPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<AndroidStreamingPreflightToPlaybackPublicApiPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingPreflightToPlaybackPublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingPreflightToPlaybackPublicApiPhysicalSmokeAppState
    extends
        State<AndroidStreamingPreflightToPlaybackPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();
  final VGStreamingPlaybackClient _playbackClient = VGStreamingPlaybackClient();

  String _status =
      'Initializing Android streaming preflight to playback all-up public API smoke…';
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

    bool preflightPass = false;
    bool planPass = false;
    bool allStreamsPass = true;
    final playbackResults = <String, dynamic>{};
    Map<String, dynamic> preflightDiag = <String, dynamic>{};
    Map<String, dynamic> planDiag = <String, dynamic>{};

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/3: Evaluating streaming preflight advisory…';
        });
      }

      // Step 1: Preflight Evaluation
      final manifestSpecs = _testCases.map((tc) {
        return VGStreamingManifestSpec(
          key: tc.key,
          uri: tc.uri,
          formatHint: tc.formatHint,
          requireAdaptiveLadder: true,
          requireAvcFallback: true,
          requireLlHlsTags: false,
          allowMediaPlaylist: false,
        );
      }).toList();

      final preflightRequest = VGStreamingPreflightRequest(
        manifests: manifestSpecs,
        requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
        preferLowLatency: false,
        allowLowLatencyOnConstrained: false,
      );

      final report = await _preflightClient.evaluate(preflightRequest);
      preflightDiag = Map<String, dynamic>.from(report.diagnostics);

      final preflightPhaseMatch = report.phase == 'Phase4C5G';
      final preflightOverallPass = report.pass == true;
      final preflightTotalMatch = report.totalReports == 3;
      final preflightFailedMatch = report.failedReports == 0;
      final preflightAdvisoryOnly = report.advisoryOnly == true;
      final preflightNoMutation = report.playbackMutation == false;

      preflightPass =
          preflightPhaseMatch &&
          preflightOverallPass &&
          preflightTotalMatch &&
          preflightFailedMatch &&
          preflightAdvisoryOnly &&
          preflightNoMutation;

      if (!preflightPass) {
        throw Exception(
          'Preflight assertion failed: phase=${report.phase}, pass=${report.pass}, '
          'total=${report.totalReports}, failed=${report.failedReports}, '
          'advisoryOnly=${report.advisoryOnly}, playbackMutation=${report.playbackMutation}',
        );
      }

      // Step 2: Synthesize Startup Plan
      if (mounted) {
        setState(() {
          _status = 'Step 2/3: Synthesizing streaming startup plan…';
        });
      }

      final plan = VGStreamingStartupPlanner.fromPreflight(report);
      planDiag = <String, dynamic>{
        'shouldProceed': plan.shouldProceed,
        'reason': plan.reason,
        'recommendedNetworkProfile': plan.recommendedNetworkProfile.toNative(),
        'warnings': plan.warnings,
      };

      final planShouldProceed = plan.shouldProceed == true;
      final planProfileMatch =
          plan.recommendedNetworkProfile ==
          VGStreamingNetworkProfile.constrained;

      planPass = planShouldProceed && planProfileMatch;

      if (!planPass) {
        throw Exception(
          'Startup plan assertion failed: shouldProceed=${plan.shouldProceed}, '
          'recommendedProfile=${plan.recommendedNetworkProfile}',
        );
      }

      // Step 3: Sequential Playback Execution per Stream
      for (final testCase in _testCases) {
        if (mounted) {
          setState(() {
            _textureId = null;
            _status = 'Step 3/3: Playing ${testCase.name}…';
          });
        }

        VGStreamingPlaybackSession? session;
        Map<String, dynamic> caseDiag = <String, dynamic>{};
        bool casePass = false;
        int renderedFrames = 0;
        int durationMs = -1;
        String stateStr = '';

        try {
          // 3a. Build validated playback options via plan
          final options = plan.buildPlaybackOptions(
            uri: testCase.uri,
            initialWidth: 1080,
            initialHeight: 1920,
            formatHint: testCase.formatHint,
            autoPlay: true,
          );

          // 3b. Open playback session
          session = await _playbackClient.open(options);
          caseDiag = Map<String, dynamic>.from(session.diagnostics);

          if (!session.pass || session.textureId < 0) {
            throw Exception(
              'Open ${testCase.name} playback failed: ${session.raw} (textureId: ${session.textureId})',
            );
          }

          final activeTextureId = session.textureId;
          if (mounted) {
            setState(() {
              _textureId = activeTextureId;
              _status =
                  '${testCase.name} active (textureId=$activeTextureId), waiting for frames…';
            });
          }

          // 3c. Explicit play call to verify public play API
          session = await _playbackClient.play(session);

          // 3d. Poll getStatus until rendered frames > 0 or max wait (12 seconds)
          const maxWaitSeconds = 12;
          final stopwatch = Stopwatch()..start();
          VGStreamingPlaybackSession status = session;
          while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            status = await _playbackClient.getStatus(session);
            caseDiag = Map<String, dynamic>.from(status.diagnostics);
            renderedFrames = status.renderedFrames;
            durationMs = status.durationMs;
            stateStr = status.state.name;
            if (renderedFrames > 0) {
              break;
            }
          }

          // 3e. Pause
          session = await _playbackClient.pause(status);
          await Future<void>.delayed(const Duration(milliseconds: 300));

          // 3f. Seek to safe position if VOD stream with positive duration
          if (testCase.isVod && durationMs > 2000) {
            final seekTargetMs = (durationMs ~/ 4).clamp(1000, 8000);
            session = await _playbackClient.seek(session, seekTargetMs);
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }

          // 3g. Stop
          session = await _playbackClient.stop(session);
          await Future<void>.delayed(const Duration(milliseconds: 200));

          // 3h. Assertions
          final statusPass = status.pass != false;
          final surfaceLost =
              status.state == VGStreamingPlaybackState.surfaceLost ||
              caseDiag['surfaceLost'] == true;
          final isFailed = status.state == VGStreamingPlaybackState.failed;

          casePass =
              statusPass && renderedFrames > 0 && !surfaceLost && !isFailed;
        } catch (error, stack) {
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PREFLIGHT_TO_PLAYBACK_PUBLIC_API_${testCase.key.toUpperCase()}_ERROR: $error\n$stack',
          );
          if (caseDiag.isEmpty) {
            caseDiag = <String, dynamic>{
              'pass': false,
              'raw': 'status=FAIL;reason=dart_exception:$error',
              'renderedFrames': 0,
            };
          }
          casePass = false;
        } finally {
          // 3i. Always dispose session
          if (session != null && session.textureId >= 0) {
            try {
              await _playbackClient.dispose(session);
            } catch (e) {
              // ignore: avoid_print
              print('Dispose error for ${testCase.name}: $e');
            }
          }
        }

        if (!casePass) {
          allStreamsPass = false;
        }

        playbackResults[testCase.key] = <String, dynamic>{
          'pass': casePass,
          'renderedFrames': renderedFrames,
          'durationMs': durationMs,
          'state': stateStr,
          'raw':
              caseDiag['raw']?.toString() ??
              (casePass ? 'status=OK' : 'status=FAIL'),
          'details': caseDiag,
        };

        if (mounted) {
          setState(() {
            _textureId = null;
            _status =
                '${testCase.name}: ${casePass ? "PASS ($renderedFrames frames)" : "FAIL"}';
          });
        }

        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_PREFLIGHT_TO_PLAYBACK_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      preflightPass = false;
      planPass = false;
      allStreamsPass = false;
    }

    final allPass = preflightPass && planPass && allStreamsPass;

    final aggregatedMap = <String, dynamic>{
      'pass': allPass,
      'preflightPass': preflightPass,
      'planPass': planPass,
      'allStreamsPass': allStreamsPass,
      'preflight': preflightDiag,
      'plan': planDiag,
      'playback': playbackResults,
    };

    // Print structured JSON and terminal markers
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_PREFLIGHT_TO_PLAYBACK_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_PREFLIGHT_TO_PLAYBACK_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_PREFLIGHT_TO_PLAYBACK_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Preflight -> Plan -> Playback (HLS: ${playbackResults['hls']?['renderedFrames']}f, DASH: ${playbackResults['dash']?['renderedFrames']}f, LL-HLS: ${playbackResults['llHls']?['renderedFrames']}f)'
            : 'FAIL: (Preflight: $preflightPass, Plan: $planPass, Playback: $allStreamsPass)';
      });
    }

    // Exit process after short delay so flutter run completes unattended
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
