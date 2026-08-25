// Vanguard iOS Phase 4C8W:
// Public streaming manifest policy validation physical smoke test.
//
// Invariants:
// - Uses public VGStreamingManifestPolicyClient API from package:vanguard_media_engine.
// - Zero raw MethodChannel and zero package:flutter/services.dart imports.
// - Validates canonical HLS, DASH, and LL-HLS multivariant manifest ladders against server ladder policy.
// - Asserts media segment URL rejection security invariant before network fetch.
// - Pure diagnostic: zero playback mutation, zero AVPlayer allocation, zero VideoToolbox decoding.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(const IosStreamingManifestPolicyPublicApiPhysicalSmokeApp());
}

class IosStreamingManifestPolicyPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingManifestPolicyPublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingManifestPolicyPublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingManifestPolicyPublicApiPhysicalSmokeAppState();
}

class _IosStreamingManifestPolicyPublicApiPhysicalSmokeAppState
    extends State<IosStreamingManifestPolicyPublicApiPhysicalSmokeApp> {
  String _status = 'Initializing iOS streaming manifest policy smoke…';
  Timer? _progressTimer;
  int _secondsElapsed = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  Future<void> _runSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    if (mounted) {
      setState(() {
        _status = 'Running iOS streaming manifest policy validation... (0s)';
      });
    }

    _progressTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _secondsElapsed += 5;
      if (mounted) {
        setState(() {
          _status =
              'Running iOS streaming manifest policy validation... (${_secondsElapsed}s)';
        });
      }
    });

    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    // ignore: avoid_print
    print('IOS_STREAMING_MANIFEST_POLICY_STEP_VALIDATE: START');

    try {
      final client = VGStreamingManifestPolicyClient();
      final request = VGStreamingManifestPolicyValidationRequest(
        manifests: <VGStreamingManifestSpec>[
          VGStreamingManifestSpec(
            key: 'mux_hls_test',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
            requireAdaptiveLadder: true,
            requireAvcFallback: true,
            requireLlHlsTags: false,
            allowMediaPlaylist: false,
          ),
          VGStreamingManifestSpec(
            key: 'shaka_angel_one_dash',
            uri: Uri.parse(
              'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
            ),
            formatHint: VGStreamingFormatHint.dash,
            requireAdaptiveLadder: true,
            requireAvcFallback: true,
            requireLlHlsTags: false,
            allowMediaPlaylist: false,
          ),
          VGStreamingManifestSpec(
            key: 'mux_ll_hls_test',
            uri: Uri.parse(
              'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
            ),
            formatHint: VGStreamingFormatHint.hls,
            requireAdaptiveLadder: true,
            requireAvcFallback: true,
            requireLlHlsTags: false,
            allowMediaPlaylist: false,
          ),
        ],
      );

      final report = await client
          .validate(request)
          .timeout(const Duration(seconds: 100));

      // ignore: avoid_print
      print('IOS_STREAMING_MANIFEST_POLICY_STEP_VALIDATE: DONE');

      final phaseMatch = report.phase == 'Phase4C5D';
      final overallPass = report.pass == true;
      final totalMatch = report.totalManifestsValidated == 3;
      final passedMatch = report.passedManifests == 3;
      final failedMatch = report.failedManifests == 0;
      final segmentRejectionMatch = report.segmentRejectionPass == true;
      final policyMatch =
          report.serverLadderPolicy ==
          'add_hevc_av1_renditions_but_keep_avc_fallback';
      final resultsLengthMatch = report.results.length == 3;

      bool allResultsPass = resultsLengthMatch;
      for (final r in report.results) {
        final rPass = r['pass'] == true;
        final rFetch = r['fetchSuccess'] == true;
        final rParse = r['parseSuccess'] == true;
        final rLadder = r['hasAdaptiveLadder'] == true;
        final rAvc = r['hasAvc'] == true;
        final rServerPass = r['serverPolicyPass'] == true;
        final rawFailures = r['policyFailures'];
        final rFailuresEmpty = rawFailures is List && rawFailures.isEmpty;

        if (!rPass ||
            !rFetch ||
            !rParse ||
            !rLadder ||
            !rAvc ||
            !rServerPass ||
            !rFailuresEmpty) {
          allResultsPass = false;
        }
      }

      final segRes = report.segmentRejectionResult;
      final segFetchSuccess = segRes['fetchSuccess'] as bool? ?? false;
      final segPass = segRes['pass'] as bool? ?? false;
      final segRaw = segRes['raw'] as String? ?? '';
      final rawInsp = segRes['inspection'];
      final segInsp = rawInsp is Map ? rawInsp : const <Object?, Object?>{};
      final segInspRaw = segInsp['raw'] as String? ?? '';
      final rawFailures = segRes['policyFailures'];
      final segFailures = rawFailures is List ? rawFailures : const [];

      final segmentRejected =
          !segFetchSuccess &&
          !segPass &&
          (segRaw.contains('media_segment_uri_rejected') ||
              segInspRaw.contains('media_segment_uri_rejected') ||
              (segFailures.length == 1 && segFailures.first == 'fetch_failed'));

      pass =
          phaseMatch &&
          overallPass &&
          totalMatch &&
          passedMatch &&
          failedMatch &&
          segmentRejectionMatch &&
          policyMatch &&
          allResultsPass &&
          segmentRejected;

      diagMap = <String, dynamic>{
        'phase': report.phase,
        'pass': report.pass,
        'totalManifestsValidated': report.totalManifestsValidated,
        'passedManifests': report.passedManifests,
        'failedManifests': report.failedManifests,
        'segmentRejectionPass': report.segmentRejectionPass,
        'serverLadderPolicy': report.serverLadderPolicy,
        'iosMirrorNote': report.iosMirrorNote,
        'results': report.results,
        'segmentRejectionResult': report.segmentRejectionResult,
        'raw': report.raw,
        'diagnostics': report.diagnostics,
        'phaseMatch': phaseMatch,
        'overallPass': overallPass,
        'totalMatch': totalMatch,
        'passedMatch': passedMatch,
        'failedMatch': failedMatch,
        'segmentRejectionMatch': segmentRejectionMatch,
        'policyMatch': policyMatch,
        'allResultsPass': allResultsPass,
        'segmentRejected': segmentRejected,
        'harnessPass': pass,
      };
    } on TimeoutException catch (e, st) {
      // ignore: avoid_print
      print('IOS_STREAMING_MANIFEST_POLICY_STEP_VALIDATE: ERROR: $e\n$st');
      diagMap = <String, dynamic>{
        'phase': 'Phase4C8W',
        'pass': false,
        'timeout': true,
        'error': e.toString(),
        'harnessPass': false,
      };
      pass = false;
    } catch (e, st) {
      // ignore: avoid_print
      print('IOS_STREAMING_MANIFEST_POLICY_STEP_VALIDATE: ERROR: $e\n$st');
      diagMap = <String, dynamic>{
        'phase': 'Phase4C8W',
        'pass': false,
        'error': e.toString(),
        'stackTrace': st.toString(),
        'harnessPass': false,
      };
      pass = false;
    } finally {
      _progressTimer?.cancel();
    }

    final jsonStr = jsonEncode(diagMap);
    // ignore: avoid_print
    print('IOS_STREAMING_MANIFEST_POLICY_PUBLIC_API_PHYSICAL_JSON:$jsonStr');

    if (pass) {
      // ignore: avoid_print
      print('IOS_STREAMING_MANIFEST_POLICY_PUBLIC_API_PHYSICAL_PASS');
      if (mounted) {
        setState(() {
          _status = 'PASS: Manifest Policy Validation Succeeded';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_MANIFEST_POLICY_PUBLIC_API_PHYSICAL_FAIL');
      if (mounted) {
        setState(() {
          _status = diagMap['timeout'] == true
              ? 'TIMEOUT: Manifest Policy Validation Timed Out'
              : 'FAIL: Manifest Policy Validation Failed';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Manifest Policy Physical Smoke')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              _status,
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
