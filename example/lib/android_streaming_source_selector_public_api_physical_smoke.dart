// Vanguard Android True-DAG Phase 4C7L: Public source selector -> preflight -> startup plan -> playback physical smoke.
//
// Sequentially verifies:
//   1. Definition of candidate streams via pure-Dart VGStreamingSourceSet and VGStreamingSourceDescriptor.
//   2. Generation of preflight request directly from sourceSet under CONSTRAINED network profile.
//   3. Preflight evaluation via VGStreamingPreflightClient.
//   4. Immutable startup plan synthesis via VGStreamingStartupPlanner.
//   5. Selection of source descriptors using pure-Dart VGStreamingSourceSelector across:
//      - preserveOrder -> selects HLS
//      - preferredKeys: ['dash'] -> selects DASH
//      - preferredKeys: ['ll_hls'] -> selects LL-HLS
//   6. Execution of adaptive streaming playback (open, play, getStatus, pause, seek, stop, dispose)
//      via VGStreamingPlaybackClient for each selection.
//
// Verification Invariants & Boundaries:
// - Imports ONLY package:vanguard_media_engine/vanguard_media_engine.dart.
// - No direct MethodChannel or services.dart imports.
// - Pure advisory validation before playback: advisoryOnly == true, playbackMutation == false.
// - Preserves source URI, initialWidth, initialHeight, formatHint in derived playback options.
// - Physical pass requires preflight pass, plan.shouldProceed == true, selector pass, and positive rendered frame counts across all sources.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const AndroidStreamingSourceSelectorPublicApiPhysicalSmokeApp());
}

class AndroidStreamingSourceSelectorPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingSourceSelectorPublicApiPhysicalSmokeApp({super.key});

  @override
  State<AndroidStreamingSourceSelectorPublicApiPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingSourceSelectorPublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingSourceSelectorPublicApiPhysicalSmokeAppState
    extends State<AndroidStreamingSourceSelectorPublicApiPhysicalSmokeApp> {
  final VGStreamingPreflightClient _preflightClient =
      VGStreamingPreflightClient();
  final VGStreamingPlaybackClient _playbackClient = VGStreamingPlaybackClient();

  String _status =
      'Initializing Android streaming source selector public API physical smoke…';
  int? _textureId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSelectorSmoke();
    });
  }

  Future<void> _runSelectorSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    bool preflightPass = false;
    bool planPass = false;
    bool allCasesPass = true;
    final caseResults = <String, dynamic>{};
    Map<String, dynamic> preflightDiag = <String, dynamic>{};
    Map<String, dynamic> planDiag = <String, dynamic>{};

    try {
      if (mounted) {
        setState(() {
          _status = 'Step 1/3: Building source set and evaluating preflight…';
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

      // Step 3: Run three selector/playback cases sequentially:
      // 1. preserveOrder should select hls
      // 2. preferredKeys: ['dash'] should select dash
      // 3. preferredKeys: ['ll_hls'] should select ll_hls
      final testCases = [
        (
          label: 'case_1_preserve_order_hls',
          expectedKey: 'hls',
          request: VGStreamingSourceSelectionRequest(
            sourceSet: sourceSet,
            startupPlan: plan,
            preference: VGStreamingSourceSelectionPreference.preserveOrder,
          ),
        ),
        (
          label: 'case_2_preferred_dash',
          expectedKey: 'dash',
          request: VGStreamingSourceSelectionRequest(
            sourceSet: sourceSet,
            startupPlan: plan,
            preference: VGStreamingSourceSelectionPreference.preserveOrder,
            preferredKeys: const ['dash'],
          ),
        ),
        (
          label: 'case_3_preferred_ll_hls',
          expectedKey: 'll_hls',
          request: VGStreamingSourceSelectionRequest(
            sourceSet: sourceSet,
            startupPlan: plan,
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
                'Step 3/3: Evaluating and playing ${testCase.label} (expecting "${testCase.expectedKey}")…';
          });
        }

        VGStreamingPlaybackSession? session;
        Map<String, dynamic> caseDiag = <String, dynamic>{};
        bool casePass = false;
        int renderedFrames = 0;
        int durationMs = -1;
        String stateStr = '';

        try {
          // 3a. Select source using pure-Dart selector
          final selection = VGStreamingSourceSelector.select(testCase.request);

          if (!selection.selected) {
            throw Exception(
              'Selector failed for ${testCase.label}: decision=${selection.decision}, warnings=${selection.warnings}',
            );
          }

          if (selection.selectedKey != testCase.expectedKey) {
            throw Exception(
              'Selector key mismatch for ${testCase.label}: selectedKey=${selection.selectedKey} vs expectedKey=${testCase.expectedKey}',
            );
          }

          final options = selection.playbackOptions;
          if (options == null) {
            throw Exception(
              'Selector playbackOptions was null for ${testCase.label}',
            );
          }

          final expectedSource = sourceSet.sourceForKey(testCase.expectedKey);
          if (options.uri != expectedSource.uri ||
              options.initialWidth != expectedSource.initialWidth ||
              options.initialHeight != expectedSource.initialHeight ||
              options.formatHint != expectedSource.formatHint ||
              options.networkProfile != VGStreamingNetworkProfile.constrained) {
            throw Exception(
              'Playback options parameter mismatch for ${testCase.label}: '
              'uri=${options.uri} vs ${expectedSource.uri}, '
              'dims=${options.initialWidth}x${options.initialHeight} vs ${expectedSource.initialWidth}x${expectedSource.initialHeight}, '
              'format=${options.formatHint} vs ${expectedSource.formatHint}, '
              'profile=${options.networkProfile}',
            );
          }

          // 3b. Open playback session
          session = await _playbackClient.open(options);
          caseDiag = Map<String, dynamic>.from(session.diagnostics);

          if (!session.pass || session.textureId < 0) {
            throw Exception(
              'Open ${testCase.expectedKey} playback failed: ${session.raw} (textureId: ${session.textureId})',
            );
          }

          final activeTextureId = session.textureId;
          if (mounted) {
            setState(() {
              _textureId = activeTextureId;
              _status =
                  '${testCase.label} active (textureId=$activeTextureId), waiting for frames…';
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

          // 3f. Seek to safe position if stream has positive duration and is safe to seek
          if (durationMs > 2000) {
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
            'ANDROID_STREAMING_SOURCE_SELECTOR_PUBLIC_API_${testCase.expectedKey.toUpperCase()}_ERROR: $error\n$stack',
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
              print('Dispose error for ${testCase.expectedKey}: $e');
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
                '${testCase.label}: ${casePass ? "PASS ($renderedFrames frames)" : "FAIL"}';
          });
        }

        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_SOURCE_SELECTOR_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      preflightPass = false;
      planPass = false;
      allCasesPass = false;
    }

    final allPass = preflightPass && planPass && allCasesPass;

    final aggregatedMap = <String, dynamic>{
      'pass': allPass,
      'preflightPass': preflightPass,
      'planPass': planPass,
      'allCasesPass': allCasesPass,
      'preflight': preflightDiag,
      'plan': planDiag,
      'cases': caseResults,
    };

    // Print structured JSON and terminal markers
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_SOURCE_SELECTOR_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(aggregatedMap)}',
    );
    // ignore: avoid_print
    print(
      allPass
          ? 'ANDROID_STREAMING_SOURCE_SELECTOR_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_SOURCE_SELECTOR_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = allPass
            ? 'PASS: Source Selector -> Preflight -> Plan -> Playback (HLS: ${caseResults['case_1_preserve_order_hls']?['renderedFrames']}f, DASH: ${caseResults['case_2_preferred_dash']?['renderedFrames']}f, LL-HLS: ${caseResults['case_3_preferred_ll_hls']?['renderedFrames']}f)'
            : 'FAIL: (Preflight: $preflightPass, Plan: $planPass, Playback: $allCasesPass)';
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
