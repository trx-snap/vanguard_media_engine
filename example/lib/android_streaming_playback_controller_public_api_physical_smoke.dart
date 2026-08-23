// Vanguard Android True-DAG Phase 4C7P: Public streaming playback controller -> physical playback smoke.
//
// Sequentially verifies:
//   1. Definition of candidate streams via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Generation of preflight request directly from sourceSet under CONSTRAINED network profile.
//   3. Preflight evaluation via VGStreamingPreflightClient.
//   4. Pure-Dart VGStreamingPlaybackDecisionPlanner planning across:
//      - preserveOrder -> selects HLS with playback_ready
//      - preferredKeys: ['dash'] -> selects DASH with playback_ready
//      - preferredKeys: ['ll_hls'] -> selects LL-HLS with playback_ready
//   5. Execution of adaptive streaming playback via VGStreamingPlaybackController:
//      - open(decision, startPlayback: true) allocating textureId
//      - Texture widget rendering
//      - polling refresh() until renderedFrames > 0
//      - pause(), optional seek(), play(), stop(), dispose()
//      - asserting snapshot.state is disposed after dispose()
//
// Verification Invariants & Boundaries:
// - Imports ONLY package:vanguard_media_engine/vanguard_media_engine.dart.
// - No direct MethodChannel or services.dart imports.
// - Pure advisory validation before playback: advisoryOnly == true, playbackMutation == false.
// - Single active session per controller; idempotent cleanup.
// - Physical pass requires preflight pass, canOpenPlayback == true, decision == 'playback_ready', positive rendered frame counts, and final disposed state across all sources.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingPlaybackControllerPublicApiPhysicalSmokeApp());
}

class AndroidStreamingPlaybackControllerPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingPlaybackControllerPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<AndroidStreamingPlaybackControllerPublicApiPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingPlaybackControllerPublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingPlaybackControllerPublicApiPhysicalSmokeAppState
    extends State<AndroidStreamingPlaybackControllerPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();

  String _status =
      'Initializing Android streaming playback controller public API physical smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runControllerSmoke();
    });
  }

  Future<void> _runControllerSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    bool preflightPass = false;
    bool allCasesPass = true;
    final caseResults = <String, dynamic>{};
    Map<String, dynamic> preflightDiag = <String, dynamic>{};

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/2: Building source set and evaluating preflight…';
        });
      }

      // Step 1: Build exactly one VGStreamingSourceSet with three descriptors
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

      // Step 2: Run three controller cases sequentially:
      // 1. preserveOrder should choose hls
      // 2. preferredKeys: ['dash'] should choose dash
      // 3. preferredKeys: ['ll_hls'] should choose ll_hls
      final testCases = [
        (
          label: 'case_1_preserve_order_hls',
          expectedKey: 'hls',
          request: VGStreamingPlaybackDecisionRequest(
            sourceSet: sourceSet,
            preflightReport: report,
            preference: VGStreamingSourceSelectionPreference.preserveOrder,
          ),
        ),
        (
          label: 'case_2_preferred_dash',
          expectedKey: 'dash',
          request: VGStreamingPlaybackDecisionRequest(
            sourceSet: sourceSet,
            preflightReport: report,
            preference: VGStreamingSourceSelectionPreference.preserveOrder,
            preferredKeys: const ['dash'],
          ),
        ),
        (
          label: 'case_3_preferred_ll_hls',
          expectedKey: 'll_hls',
          request: VGStreamingPlaybackDecisionRequest(
            sourceSet: sourceSet,
            preflightReport: report,
            preference: VGStreamingSourceSelectionPreference.preserveOrder,
            preferredKeys: const ['ll_hls'],
          ),
        ),
      ];

      for (final testCase in testCases) {
        if (mounted) {
          setState(() {
            _textureId = null;
            _status =
                'Step 2/2: Planning and controlling ${testCase.label} (expecting "${testCase.expectedKey}")…';
          });
        }

        VGStreamingPlaybackController? controller;
        Map<String, dynamic> caseDiag = <String, dynamic>{};
        bool casePass = false;
        int renderedFrames = 0;
        int durationMs = -1;
        String finalStateStr = '';

        try {
          // 2a. Build VGStreamingPlaybackDecision
          final decision = VGStreamingPlaybackDecisionPlanner.plan(
            testCase.request,
          );

          if (!decision.canOpenPlayback) {
            throw Exception(
              'Planner canOpenPlayback was false for ${testCase.label}: decision=${decision.decision}, warnings=${decision.warnings}',
            );
          }

          if (decision.decision != 'playback_ready') {
            throw Exception(
              'Planner decision was "${decision.decision}" (expected "playback_ready") for ${testCase.label}',
            );
          }

          if (decision.selectedKey != testCase.expectedKey) {
            throw Exception(
              'Planner key mismatch for ${testCase.label}: selectedKey=${decision.selectedKey} vs expectedKey=${testCase.expectedKey}',
            );
          }

          // 2b. Create a fresh VGStreamingPlaybackController
          controller = VGStreamingPlaybackController();

          // 2c. Open playback session via controller
          final openSnapshot = await controller.open(
            decision,
            startPlayback: true,
          );
          if (!openSnapshot.pass || openSnapshot.textureId == null) {
            throw Exception(
              'Controller open failed for ${testCase.expectedKey}: pass=${openSnapshot.pass}, '
              'reason=${openSnapshot.reason}, lastError=${openSnapshot.lastError}, textureId=${openSnapshot.textureId}',
            );
          }

          final activeTextureId = openSnapshot.textureId!;
          if (mounted) {
            setState(() {
              _textureId = activeTextureId;
              _status =
                  '${testCase.label} active (textureId=$activeTextureId), waiting for frames…';
            });
          }

          // 2d. Poll controller.refresh() until renderedFrames > 0 or timeout (12 seconds)
          const maxWaitSeconds = 12;
          final stopwatch = Stopwatch()..start();
          VGStreamingPlaybackControllerSnapshot refreshSnapshot = openSnapshot;
          while (stopwatch.elapsed < const Duration(seconds: maxWaitSeconds)) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            refreshSnapshot = await controller.refresh();
            caseDiag = Map<String, dynamic>.from(refreshSnapshot.diagnostics);
            renderedFrames = refreshSnapshot.session?.renderedFrames ?? 0;
            durationMs = refreshSnapshot.session?.durationMs ?? -1;
            if (renderedFrames > 0) {
              break;
            }
          }

          // 2e. Pause
          final pauseSnapshot = await controller.pause();
          if (!pauseSnapshot.pass) {
            throw Exception(
              'Controller pause failed for ${testCase.expectedKey}: reason=${pauseSnapshot.reason}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));

          // 2f. Safe seek if duration allows
          if (durationMs > 2000) {
            final seekTargetMs = (durationMs ~/ 4).clamp(1000, 8000);
            final seekSnapshot = await controller.seek(seekTargetMs);
            if (!seekSnapshot.pass) {
              throw Exception(
                'Controller seek failed for ${testCase.expectedKey}: reason=${seekSnapshot.reason}',
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }

          // 2g. Play
          final playSnapshot = await controller.play();
          if (!playSnapshot.pass) {
            throw Exception(
              'Controller play resume failed for ${testCase.expectedKey}: reason=${playSnapshot.reason}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));

          // 2h. Stop
          final stopSnapshot = await controller.stop();
          if (!stopSnapshot.pass) {
            throw Exception(
              'Controller stop failed for ${testCase.expectedKey}: reason=${stopSnapshot.reason}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));

          // 2i. Dispose
          final disposeSnapshot = await controller.dispose();
          if (!disposeSnapshot.pass ||
              disposeSnapshot.state !=
                  VGStreamingPlaybackControllerState.disposed) {
            throw Exception(
              'Controller dispose failed for ${testCase.expectedKey}: state=${disposeSnapshot.state}, pass=${disposeSnapshot.pass}',
            );
          }
          finalStateStr = disposeSnapshot.state.name;

          // 2j. Assertions
          final statusPass = refreshSnapshot.pass;
          final isFailed =
              refreshSnapshot.state ==
              VGStreamingPlaybackControllerState.failed;
          final isDisposed =
              disposeSnapshot.state ==
              VGStreamingPlaybackControllerState.disposed;

          casePass =
              statusPass && renderedFrames > 0 && !isFailed && isDisposed;
        } catch (error, stack) {
          // ignore: avoid_print
          print(
            'ANDROID_STREAMING_PLAYBACK_CONTROLLER_PUBLIC_API_${testCase.expectedKey.toUpperCase()}_ERROR: $error\n$stack',
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
          // Always ensure controller is disposed
          if (controller != null && !controller.isDisposed) {
            try {
              await controller.dispose();
            } catch (e) {
              // ignore: avoid_print
              print('Dispose error in finally for ${testCase.expectedKey}: $e');
            }
          }
        }

        if (!casePass) {
          allCasesPass = false;
        }

        caseResults[testCase.label] = <String, dynamic>{
          'selectedKey': testCase.expectedKey,
          'pass': casePass,
          'renderedFrames': renderedFrames,
          'durationMs': durationMs,
          'finalState': finalStateStr,
          'raw':
              caseDiag['raw']?.toString() ??
              (casePass ? 'status=OK' : 'status=FAIL'),
          'details': caseDiag,
        };

        if (mounted) {
          setState(() {
            _textureId = null;
            _status =
                '${testCase.label}: ${casePass ? "PASS ($renderedFrames frames)" : "FAIL"}';
          });
        }

        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_PLAYBACK_CONTROLLER_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      preflightPass = false;
      allCasesPass = false;
    }

    final allPass = preflightPass && allCasesPass;

    final aggregatedMap = <String, dynamic>{
      'pass': allPass,
      'preflightPass': preflightPass,
      'allCasesPass': allCasesPass,
      'preflight': preflightDiag,
      'cases': caseResults,
    };

    // Print structured JSON and terminal markers
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_PLAYBACK_CONTROLLER_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_PLAYBACK_CONTROLLER_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_PLAYBACK_CONTROLLER_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Playback Controller -> Physical Playback (HLS: ${caseResults['case_1_preserve_order_hls']?['renderedFrames']}f, DASH: ${caseResults['case_2_preferred_dash']?['renderedFrames']}f, LL-HLS: ${caseResults['case_3_preferred_ll_hls']?['renderedFrames']}f)'
            : 'FAIL: (Preflight: $preflightPass, Playback: $allCasesPass)';
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
