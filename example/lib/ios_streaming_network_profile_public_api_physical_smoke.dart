// Copyright (c) Connects — Vanguard Phase 4C8Y.
// Public streaming network-profile policy physical smoke test on iOS.
//
// Sequentially verifies AVPlayer network-profile policy application and diagnostic telemetry
// across four profiles using the public VGStreamingPlaybackClient API:
//   1. AUTO        (Mux HLS)         - standard AVPlayer defaults
//   2. STABLE      (Mux HLS)         - aggressive readahead, no peak bitrate cap
//   3. CONSTRAINED (Mux HLS)         - deep buffer, 896kbps peak bitrate cap (800k video + 96k audio)
//   4. LOW_LATENCY (Mux LL-HLS)      - shallow buffer, automaticallyWaitsToMinimizeStalling=false
//
// Invariants & Requirements:
// - Uses public VGStreamingPlaybackClient and VGStreamingPlaybackOptions only.
// - Zero raw MethodChannel and zero package:flutter/services.dart imports.
// - Bounded async timeouts for all operations (open: 20s, dispose: 8s).
// - Defensively extracts diagnostics['streamingNetworkPolicy'] and asserts all fields.
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
const Duration _kDisposeTimeout = Duration(seconds: 8);

class _NetworkProfileTestCase {
  final String tag;
  final VGStreamingNetworkProfile profile;
  final Uri uri;
  final VGStreamingFormatHint formatHint;
  final bool autoPlay;

  // Expected policy fields
  final bool expectedCustomPolicyEnabled;
  final int? expectedMinBufferMs;
  final int? expectedMaxBufferMs;
  final int? expectedBufferForPlaybackMs;
  final int? expectedBufferForPlaybackAfterRebufferMs;
  final int? expectedMaxVideoBitrate;
  final int? expectedMaxAudioBitrate;
  final bool expectedForceLowestBitrate;
  final bool expectedExceedVideoConstraintsIfNecessary;
  final double expectedPreferredForwardBufferDurationSeconds;
  final double expectedPreferredPeakBitRate;
  final bool expectedAutomaticallyWaitsToMinimizeStalling;

  const _NetworkProfileTestCase({
    required this.tag,
    required this.profile,
    required this.uri,
    required this.formatHint,
    required this.autoPlay,
    required this.expectedCustomPolicyEnabled,
    required this.expectedMinBufferMs,
    required this.expectedMaxBufferMs,
    required this.expectedBufferForPlaybackMs,
    required this.expectedBufferForPlaybackAfterRebufferMs,
    required this.expectedMaxVideoBitrate,
    required this.expectedMaxAudioBitrate,
    required this.expectedForceLowestBitrate,
    required this.expectedExceedVideoConstraintsIfNecessary,
    required this.expectedPreferredForwardBufferDurationSeconds,
    required this.expectedPreferredPeakBitRate,
    required this.expectedAutomaticallyWaitsToMinimizeStalling,
  });
}

final List<_NetworkProfileTestCase> _scenarios = [
  _NetworkProfileTestCase(
    tag: 'AUTO',
    profile: VGStreamingNetworkProfile.auto,
    uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
    formatHint: VGStreamingFormatHint.hls,
    autoPlay: false,
    expectedCustomPolicyEnabled: false,
    expectedMinBufferMs: null,
    expectedMaxBufferMs: null,
    expectedBufferForPlaybackMs: null,
    expectedBufferForPlaybackAfterRebufferMs: null,
    expectedMaxVideoBitrate: null,
    expectedMaxAudioBitrate: null,
    expectedForceLowestBitrate: false,
    expectedExceedVideoConstraintsIfNecessary: false,
    expectedPreferredForwardBufferDurationSeconds: 0.0,
    expectedPreferredPeakBitRate: 0.0,
    expectedAutomaticallyWaitsToMinimizeStalling: true,
  ),
  _NetworkProfileTestCase(
    tag: 'STABLE',
    profile: VGStreamingNetworkProfile.stable,
    uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
    formatHint: VGStreamingFormatHint.hls,
    autoPlay: false,
    expectedCustomPolicyEnabled: true,
    expectedMinBufferMs: 15000,
    expectedMaxBufferMs: 50000,
    expectedBufferForPlaybackMs: 2500,
    expectedBufferForPlaybackAfterRebufferMs: 5000,
    expectedMaxVideoBitrate: null,
    expectedMaxAudioBitrate: null,
    expectedForceLowestBitrate: false,
    expectedExceedVideoConstraintsIfNecessary: true,
    expectedPreferredForwardBufferDurationSeconds: 15.0,
    expectedPreferredPeakBitRate: 0.0,
    expectedAutomaticallyWaitsToMinimizeStalling: true,
  ),
  _NetworkProfileTestCase(
    tag: 'CONSTRAINED',
    profile: VGStreamingNetworkProfile.constrained,
    uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
    formatHint: VGStreamingFormatHint.hls,
    autoPlay: false,
    expectedCustomPolicyEnabled: true,
    expectedMinBufferMs: 25000,
    expectedMaxBufferMs: 60000,
    expectedBufferForPlaybackMs: 5000,
    expectedBufferForPlaybackAfterRebufferMs: 8000,
    expectedMaxVideoBitrate: 800000,
    expectedMaxAudioBitrate: 96000,
    expectedForceLowestBitrate: false,
    expectedExceedVideoConstraintsIfNecessary: true,
    expectedPreferredForwardBufferDurationSeconds: 25.0,
    expectedPreferredPeakBitRate: 896000.0,
    expectedAutomaticallyWaitsToMinimizeStalling: true,
  ),
  _NetworkProfileTestCase(
    tag: 'LOW_LATENCY',
    profile: VGStreamingNetworkProfile.lowLatency,
    uri: Uri.parse(
      'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
    ),
    formatHint: VGStreamingFormatHint.hls,
    autoPlay: false,
    expectedCustomPolicyEnabled: true,
    expectedMinBufferMs: 3000,
    expectedMaxBufferMs: 10000,
    expectedBufferForPlaybackMs: 1000,
    expectedBufferForPlaybackAfterRebufferMs: 1500,
    expectedMaxVideoBitrate: null,
    expectedMaxAudioBitrate: null,
    expectedForceLowestBitrate: false,
    expectedExceedVideoConstraintsIfNecessary: true,
    expectedPreferredForwardBufferDurationSeconds: 3.0,
    expectedPreferredPeakBitRate: 0.0,
    expectedAutomaticallyWaitsToMinimizeStalling: false,
  ),
];

void main() {
  runApp(const IosStreamingNetworkProfilePublicApiPhysicalSmokeApp());
}

class IosStreamingNetworkProfilePublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const IosStreamingNetworkProfilePublicApiPhysicalSmokeApp({super.key});

  @override
  State<IosStreamingNetworkProfilePublicApiPhysicalSmokeApp> createState() =>
      _IosStreamingNetworkProfilePublicApiPhysicalSmokeAppState();
}

class _IosStreamingNetworkProfilePublicApiPhysicalSmokeAppState
    extends State<IosStreamingNetworkProfilePublicApiPhysicalSmokeApp> {
  final VGStreamingPlaybackClient _client = VGStreamingPlaybackClient();
  String _status = 'Bootstrapping iOS streaming network profile smoke...';

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() async {
      try {
        await _runSmoke();
      } catch (error, stack) {
        // ignore: avoid_print
        print('IOS_STREAMING_NETWORK_PROFILE_BOOTSTRAP_ERROR: $error\n$stack');
        // ignore: avoid_print
        print('IOS_STREAMING_NETWORK_PROFILE_PUBLIC_API_PHYSICAL_FAIL');
        await Future<void>.delayed(const Duration(seconds: 1));
        exit(1);
      }
    });
  }

  Map<String, Object?> _extractMapDefensively(Object? raw) {
    if (raw is! Map) return <String, Object?>{};
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      final key = entry.key?.toString();
      if (key != null) {
        result[key] = entry.value;
      }
    }
    return result;
  }

  Future<void> _runSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    final profilePassMap = <String, bool>{};
    final policySummaries = <String, dynamic>{};
    final errors = <String>[];
    bool overallPass = true;

    for (final scenario in _scenarios) {
      final tag = scenario.tag;
      // ignore: avoid_print
      print('IOS_STREAMING_NETWORK_PROFILE_STEP_${tag}_OPEN: START');

      if (mounted) {
        setState(() {
          _status = 'Running scenario: $tag (${scenario.profile.name})…';
        });
      }

      VGStreamingPlaybackSession? session;
      bool scenarioPass = false;

      try {
        session = await _client
            .open(
              VGStreamingPlaybackOptions(
                uri: scenario.uri,
                initialWidth: _initialWidth,
                initialHeight: _initialHeight,
                formatHint: scenario.formatHint,
                networkProfile: scenario.profile,
                autoPlay: scenario.autoPlay,
              ),
            )
            .timeout(_kOpenTimeout);

        if (!session.pass) {
          throw Exception(
            '[$tag] Session open returned pass=false, raw=${session.raw}',
          );
        }

        if (session.textureId < 0) {
          throw Exception(
            '[$tag] Invalid textureId returned: ${session.textureId}',
          );
        }

        final diag = session.diagnostics;

        // Top-level profile name assertion
        final diagNetworkProfile = diag['networkProfile'] as String?;
        final diagStreamingNetworkProfile =
            diag['streamingNetworkProfile'] as String?;

        if (diagNetworkProfile != tag) {
          throw Exception(
            '[$tag] diagnostics["networkProfile"] mismatch: expected "$tag", got "$diagNetworkProfile"',
          );
        }

        if (diagStreamingNetworkProfile != tag) {
          throw Exception(
            '[$tag] diagnostics["streamingNetworkProfile"] mismatch: expected "$tag", got "$diagStreamingNetworkProfile"',
          );
        }

        // Top-level AVFoundation application fields
        final topPreferredForwardBufferDuration =
            (diag['preferredForwardBufferDurationSeconds'] as num?)?.toDouble();
        final topPreferredPeakBitRate = (diag['preferredPeakBitRate'] as num?)
            ?.toDouble();
        final topAutomaticallyWaits =
            diag['automaticallyWaitsToMinimizeStalling'] as bool?;

        if (topPreferredForwardBufferDuration !=
            scenario.expectedPreferredForwardBufferDurationSeconds) {
          throw Exception(
            '[$tag] Top-level preferredForwardBufferDurationSeconds mismatch: '
            'expected ${scenario.expectedPreferredForwardBufferDurationSeconds}, got $topPreferredForwardBufferDuration',
          );
        }

        if (topPreferredPeakBitRate != scenario.expectedPreferredPeakBitRate) {
          throw Exception(
            '[$tag] Top-level preferredPeakBitRate mismatch: '
            'expected ${scenario.expectedPreferredPeakBitRate}, got $topPreferredPeakBitRate',
          );
        }

        if (topAutomaticallyWaits !=
            scenario.expectedAutomaticallyWaitsToMinimizeStalling) {
          throw Exception(
            '[$tag] Top-level automaticallyWaitsToMinimizeStalling mismatch: '
            'expected ${scenario.expectedAutomaticallyWaitsToMinimizeStalling}, got $topAutomaticallyWaits',
          );
        }

        // Defensively extract nested streamingNetworkPolicy map
        final policyMap = _extractMapDefensively(
          diag['streamingNetworkPolicy'],
        );
        if (policyMap.isEmpty) {
          throw Exception(
            '[$tag] diagnostics["streamingNetworkPolicy"] is missing or not a Map',
          );
        }

        final customPolicyEnabled =
            policyMap['customPolicyEnabled'] as bool? ?? false;
        final minBufferMs = (policyMap['minBufferMs'] as num?)?.toInt();
        final maxBufferMs = (policyMap['maxBufferMs'] as num?)?.toInt();
        final bufferForPlaybackMs = (policyMap['bufferForPlaybackMs'] as num?)
            ?.toInt();
        final bufferForPlaybackAfterRebufferMs =
            (policyMap['bufferForPlaybackAfterRebufferMs'] as num?)?.toInt();
        final maxVideoBitrate = (policyMap['maxVideoBitrate'] as num?)?.toInt();
        final maxAudioBitrate = (policyMap['maxAudioBitrate'] as num?)?.toInt();
        final forceLowestBitrate =
            policyMap['forceLowestBitrate'] as bool? ?? false;
        final exceedVideoConstraintsIfNecessary =
            policyMap['exceedVideoConstraintsIfNecessary'] as bool? ?? false;
        final policyPreferredForwardBufferDuration =
            (policyMap['preferredForwardBufferDurationSeconds'] as num?)
                ?.toDouble();
        final policyPreferredPeakBitRate =
            (policyMap['preferredPeakBitRate'] as num?)?.toDouble();
        final policyAutomaticallyWaits =
            policyMap['automaticallyWaitsToMinimizeStalling'] as bool?;

        if (customPolicyEnabled != scenario.expectedCustomPolicyEnabled) {
          throw Exception(
            '[$tag] policy["customPolicyEnabled"] mismatch: expected ${scenario.expectedCustomPolicyEnabled}, got $customPolicyEnabled',
          );
        }

        if (minBufferMs != scenario.expectedMinBufferMs) {
          throw Exception(
            '[$tag] policy["minBufferMs"] mismatch: expected ${scenario.expectedMinBufferMs}, got $minBufferMs',
          );
        }

        if (maxBufferMs != scenario.expectedMaxBufferMs) {
          throw Exception(
            '[$tag] policy["maxBufferMs"] mismatch: expected ${scenario.expectedMaxBufferMs}, got $maxBufferMs',
          );
        }

        if (bufferForPlaybackMs != scenario.expectedBufferForPlaybackMs) {
          throw Exception(
            '[$tag] policy["bufferForPlaybackMs"] mismatch: expected ${scenario.expectedBufferForPlaybackMs}, got $bufferForPlaybackMs',
          );
        }

        if (bufferForPlaybackAfterRebufferMs !=
            scenario.expectedBufferForPlaybackAfterRebufferMs) {
          throw Exception(
            '[$tag] policy["bufferForPlaybackAfterRebufferMs"] mismatch: expected ${scenario.expectedBufferForPlaybackAfterRebufferMs}, got $bufferForPlaybackAfterRebufferMs',
          );
        }

        if (maxVideoBitrate != scenario.expectedMaxVideoBitrate) {
          throw Exception(
            '[$tag] policy["maxVideoBitrate"] mismatch: expected ${scenario.expectedMaxVideoBitrate}, got $maxVideoBitrate',
          );
        }

        if (maxAudioBitrate != scenario.expectedMaxAudioBitrate) {
          throw Exception(
            '[$tag] policy["maxAudioBitrate"] mismatch: expected ${scenario.expectedMaxAudioBitrate}, got $maxAudioBitrate',
          );
        }

        if (forceLowestBitrate != scenario.expectedForceLowestBitrate) {
          throw Exception(
            '[$tag] policy["forceLowestBitrate"] mismatch: expected ${scenario.expectedForceLowestBitrate}, got $forceLowestBitrate',
          );
        }

        if (exceedVideoConstraintsIfNecessary !=
            scenario.expectedExceedVideoConstraintsIfNecessary) {
          throw Exception(
            '[$tag] policy["exceedVideoConstraintsIfNecessary"] mismatch: expected ${scenario.expectedExceedVideoConstraintsIfNecessary}, got $exceedVideoConstraintsIfNecessary',
          );
        }

        if (policyPreferredForwardBufferDuration !=
            scenario.expectedPreferredForwardBufferDurationSeconds) {
          throw Exception(
            '[$tag] policy["preferredForwardBufferDurationSeconds"] mismatch: expected ${scenario.expectedPreferredForwardBufferDurationSeconds}, got $policyPreferredForwardBufferDuration',
          );
        }

        if (policyPreferredPeakBitRate !=
            scenario.expectedPreferredPeakBitRate) {
          throw Exception(
            '[$tag] policy["preferredPeakBitRate"] mismatch: expected ${scenario.expectedPreferredPeakBitRate}, got $policyPreferredPeakBitRate',
          );
        }

        if (policyAutomaticallyWaits !=
            scenario.expectedAutomaticallyWaitsToMinimizeStalling) {
          throw Exception(
            '[$tag] policy["automaticallyWaitsToMinimizeStalling"] mismatch: expected ${scenario.expectedAutomaticallyWaitsToMinimizeStalling}, got $policyAutomaticallyWaits',
          );
        }

        // ignore: avoid_print
        print(
          'IOS_STREAMING_NETWORK_PROFILE_STEP_${tag}_OPEN: DONE (textureId=${session.textureId})',
        );

        policySummaries[tag] = <String, dynamic>{
          'pass': true,
          'textureId': session.textureId,
          'networkProfile': diagNetworkProfile,
          'streamingNetworkProfile': diagStreamingNetworkProfile,
          'streamingNetworkPolicy': policyMap,
          'preferredForwardBufferDurationSeconds':
              topPreferredForwardBufferDuration,
          'preferredPeakBitRate': topPreferredPeakBitRate,
          'automaticallyWaitsToMinimizeStalling': topAutomaticallyWaits,
        };

        scenarioPass = true;
      } catch (e) {
        scenarioPass = false;
        overallPass = false;
        final errorMsg = 'Scenario $tag failed: $e';
        errors.add(errorMsg);
        // ignore: avoid_print
        print('IOS_STREAMING_NETWORK_PROFILE_STEP_${tag}_ERROR: $e');
        policySummaries[tag] = <String, dynamic>{
          'pass': false,
          'error': e.toString(),
        };
      } finally {
        profilePassMap[tag] = scenarioPass;

        if (session != null && session.textureId >= 0) {
          // ignore: avoid_print
          print('IOS_STREAMING_NETWORK_PROFILE_STEP_${tag}_DISPOSE: START');
          try {
            await _client.dispose(session).timeout(_kDisposeTimeout);
            // ignore: avoid_print
            print('IOS_STREAMING_NETWORK_PROFILE_STEP_${tag}_DISPOSE: DONE');
          } catch (disposeErr) {
            overallPass = false;
            final disposeMsg = '[$tag] Dispose failed: $disposeErr';
            errors.add(disposeMsg);
            // ignore: avoid_print
            print(
              'IOS_STREAMING_NETWORK_PROFILE_STEP_${tag}_DISPOSE_ERROR: $disposeErr',
            );
          }
        }
      }
    }

    final terminalJson = <String, dynamic>{
      'phase': 'Phase4C8Y',
      'target': 'ios_physical',
      'pass': overallPass,
      'profilePass': profilePassMap,
      'policySummaries': policySummaries,
      if (errors.isNotEmpty) 'errors': errors,
    };

    // Emit terminal JSON
    // ignore: avoid_print
    print(
      'IOS_STREAMING_NETWORK_PROFILE_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(terminalJson)}',
    );

    // Emit terminal marker
    if (overallPass) {
      // ignore: avoid_print
      print('IOS_STREAMING_NETWORK_PROFILE_PUBLIC_API_PHYSICAL_PASS');
      if (mounted) {
        setState(() {
          _status = 'ALL 4 NETWORK PROFILE SCENARIOS PASSED';
        });
      }
    } else {
      // ignore: avoid_print
      print('IOS_STREAMING_NETWORK_PROFILE_PUBLIC_API_PHYSICAL_FAIL');
      if (mounted) {
        setState(() {
          _status = 'NETWORK PROFILE SMOKE FAILED: ${errors.join('; ')}';
        });
      }
    }

    await Future<void>.delayed(const Duration(seconds: 1));
    exit(overallPass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('iOS Network Profile Physical Smoke')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16.0),
            ),
          ),
        ),
      ),
    );
  }
}
