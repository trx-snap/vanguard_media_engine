// Vanguard Android True-DAG Phase 4C5N/4C5O:
// Public streaming compatibility decision API physical smoke test.
//
// Invariants:
// - Uses public VGStreamingCompatibilityDecisionClient API from package:vanguard_media_engine.
// - Zero raw MethodChannel and zero package:flutter/services.dart imports.
// - Evaluates HLS, DASH, and LL-HLS candidate manifest ladders against device codec capabilities.
// - Enforces additive server ladder policy: add_hevc_av1_renditions_but_keep_avc_fallback.
// - Zero playback mutation, zero ExoPlayer allocation, zero MediaCodec decoding, zero surface allocation.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  runApp(
    const AndroidStreamingCompatibilityDecisionPublicApiPhysicalSmokeApp(),
  );
}

class AndroidStreamingCompatibilityDecisionPublicApiPhysicalSmokeApp
    extends StatefulWidget {
  const AndroidStreamingCompatibilityDecisionPublicApiPhysicalSmokeApp({
    super.key,
  });

  @override
  State<AndroidStreamingCompatibilityDecisionPublicApiPhysicalSmokeApp>
  createState() =>
      _AndroidStreamingCompatibilityDecisionPublicApiPhysicalSmokeAppState();
}

class _AndroidStreamingCompatibilityDecisionPublicApiPhysicalSmokeAppState
    extends
        State<AndroidStreamingCompatibilityDecisionPublicApiPhysicalSmokeApp> {
  String _status =
      'Initializing public streaming compatibility decision smoke…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runSmoke();
    });
  }

  Future<void> _runSmoke() async {
    // Wait briefly for Flutter host connection to settle
    await Future<void>.delayed(const Duration(seconds: 1));

    Map<String, dynamic> diagMap = <String, dynamic>{};
    bool pass = false;

    try {
      final client = VGStreamingCompatibilityDecisionClient();
      final request = VGStreamingCompatibilityDecisionRequest(
        manifests: [
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

      final report = await client.evaluate(request);

      diagMap = <String, dynamic>{
        'phase': report.phase,
        'pass': report.pass,
        'totalReports': report.totalReports,
        'passedReports': report.passedReports,
        'failedReports': report.failedReports,
        'codecProbePass': report.codecProbePass,
        'avcSupported': report.avcSupported,
        'hevcSupported': report.hevcSupported,
        'av1Supported': report.av1Supported,
        'av1HardwareSafe': report.av1HardwareSafe,
        'deviceWarnings': report.deviceWarnings,
        'serverLadderPolicy': report.serverLadderPolicy,
        'iosMirrorNote': report.iosMirrorNote,
        'reports': report.reports
            .map(
              (r) => <String, dynamic>{
                'key': r.key,
                'uri': r.uri,
                'formatHint': r.formatHint,
                'pass': r.pass,
                'manifestPolicyPass': r.manifestPolicyPass,
                'avcManifestPresent': r.avcManifestPresent,
                'hevcManifestPresent': r.hevcManifestPresent,
                'av1ManifestPresent': r.av1ManifestPresent,
                'avcDeviceSupported': r.avcDeviceSupported,
                'hevcDeviceSupported': r.hevcDeviceSupported,
                'av1DeviceSupported': r.av1DeviceSupported,
                'avcHardwareSafe': r.avcHardwareSafe,
                'hevcHardwareSafe': r.hevcHardwareSafe,
                'av1HardwareSafe': r.av1HardwareSafe,
                'preferredCodecFamily': r.preferredCodecFamily,
                'fallbackCodecFamily': r.fallbackCodecFamily,
                'safeCodecFamilies': r.safeCodecFamilies,
                'riskyCodecFamilies': r.riskyCodecFamilies,
                'warnings': r.warnings,
                'renditionCount': r.renditionCount,
                'lowestBandwidth': r.lowestBandwidth,
                'highestBandwidth': r.highestBandwidth,
                'decision': r.decision,
                'raw': r.raw,
                'manifestValidation': r.manifestValidation,
              },
            )
            .toList(),
        'raw': report.raw,
        'diagnostics': report.diagnostics,
      };

      final phaseMatch = report.phase == 'Phase4C5E';
      final overallPass = report.pass == true;
      final totalMatch = report.totalReports == 3;
      final passedMatch = report.passedReports == 3;
      final failedMatch = report.failedReports == 0;
      final probeMatch = report.codecProbePass == true;
      final avcMatch = report.avcSupported == true;
      final reportsCountMatch = report.reports.length == 3;
      final allEntriesValid =
          report.reports.isNotEmpty &&
          report.reports.every((r) {
            return r.pass == true &&
                !r.decision.startsWith('blocked_') &&
                r.preferredCodecFamily.isNotEmpty &&
                r.preferredCodecFamily != 'none';
          });
      final policyMatch = report.serverLadderPolicy.contains(
        'add_hevc_av1_renditions_but_keep_avc_fallback',
      );

      pass =
          phaseMatch &&
          overallPass &&
          totalMatch &&
          passedMatch &&
          failedMatch &&
          probeMatch &&
          avcMatch &&
          reportsCountMatch &&
          allEntriesValid &&
          policyMatch;
    } catch (error, stack) {
      // ignore: avoid_print
      print(
        'ANDROID_STREAMING_COMPATIBILITY_DECISION_PUBLIC_API_PHYSICAL_ERROR: $error\n$stack',
      );
      if (diagMap.isEmpty) {
        diagMap = <String, dynamic>{
          'pass': false,
          'raw': 'status=FAIL;reason=dart_exception:$error',
        };
      }
      pass = false;
    }

    final totalReports = diagMap['totalReports'] ?? 0;
    final passedReports = diagMap['passedReports'] ?? 0;
    final failedReports = diagMap['failedReports'] ?? 0;

    // Print diagnostic map and terminal marker
    // ignore: avoid_print
    print(
      'ANDROID_STREAMING_COMPATIBILITY_DECISION_PUBLIC_API_PHYSICAL_JSON:${jsonEncode(diagMap)}',
    );
    // ignore: avoid_print
    print(
      pass
          ? 'ANDROID_STREAMING_COMPATIBILITY_DECISION_PUBLIC_API_PHYSICAL_PASS'
          : 'ANDROID_STREAMING_COMPATIBILITY_DECISION_PUBLIC_API_PHYSICAL_FAIL',
    );

    if (mounted) {
      setState(() {
        _status = pass
            ? 'PASS (Reports=$totalReports, Passed=$passedReports, Failed=$failedReports)'
            : 'FAIL: ${diagMap['raw']}';
      });
    }

    // Exit process after marker so flutter run can finish unattended
    await Future<void>.delayed(const Duration(seconds: 1));
    exit(pass ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
