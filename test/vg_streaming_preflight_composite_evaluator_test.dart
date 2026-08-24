import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vg_streaming_codec_capability_client.dart';
import 'package:vanguard_media_engine/vg_streaming_compatibility_decision_client.dart';
import 'package:vanguard_media_engine/vg_streaming_manifest_policy_client.dart';
import 'package:vanguard_media_engine/vg_streaming_preflight_client.dart';
import 'package:vanguard_media_engine/vg_streaming_preflight_composite_evaluator.dart';

void main() {
  VGStreamingManifestPolicyValidationReport createManifestReport({
    bool pass = true,
    String phase = 'Phase4C5D',
    int totalManifestsValidated = 2,
    int passedManifests = 2,
    int failedManifests = 0,
    bool segmentRejectionPass = true,
    String serverLadderPolicy = 'manifest_policy',
    String iosMirrorNote = 'manifest_note',
  }) {
    return VGStreamingManifestPolicyValidationReport(
      pass: pass,
      phase: phase,
      totalManifestsValidated: totalManifestsValidated,
      passedManifests: passedManifests,
      failedManifests: failedManifests,
      segmentRejectionPass: segmentRejectionPass,
      serverLadderPolicy: serverLadderPolicy,
      iosMirrorNote: iosMirrorNote,
      results: const <Map<String, Object?>>[],
      segmentRejectionResult: const <String, Object?>{},
      raw: 'raw_manifest',
      diagnostics: const <String, Object?>{'manifest_key': 'val'},
    );
  }

  VGStreamingCodecCapabilityReport createCodecReport({
    bool pass = true,
    String phase = 'Phase4C5A',
    bool avcPass = true,
    bool codecCountPass = true,
    bool fallbackPolicyPass = true,
    bool iosMirrorNotePass = true,
    bool avcSupported = true,
    bool hevcSupported = true,
    bool av1Supported = false,
    int androidSdk = 34,
    String serverLadderPolicy = 'codec_policy',
    String iosMirrorNote = 'codec_note',
  }) {
    return VGStreamingCodecCapabilityReport(
      pass: pass,
      phase: phase,
      avcPass: avcPass,
      codecCountPass: codecCountPass,
      fallbackPolicyPass: fallbackPolicyPass,
      iosMirrorNotePass: iosMirrorNotePass,
      avcSupported: avcSupported,
      hevcSupported: hevcSupported,
      av1Supported: av1Supported,
      androidSdk: androidSdk,
      serverLadderPolicy: serverLadderPolicy,
      iosMirrorNote: iosMirrorNote,
      codecs: const <VGStreamingCodecInfo>[],
      probe: const <String, Object?>{},
      raw: 'raw_codec',
      diagnostics: const <String, Object?>{'codec_key': 'val'},
    );
  }

  VGStreamingCompatibilityDecisionReport createCompatibilityReport({
    bool pass = true,
    String phase = 'Phase4C5E',
    int totalReports = 2,
    int passedReports = 2,
    int failedReports = 0,
    bool codecProbePass = true,
    bool avcSupported = true,
    bool hevcSupported = true,
    bool av1Supported = false,
    bool av1HardwareSafe = false,
    List<String> deviceWarnings = const ['device_warn_1'],
    String serverLadderPolicy = 'compat_policy',
    String iosMirrorNote = 'compat_note',
    List<VGStreamingCompatibilityDecisionEntry>? reports,
  }) {
    final defaultReports =
        reports ??
        const [
          VGStreamingCompatibilityDecisionEntry(
            key: 'stream_1',
            uri: 'https://example.com/stream1.m3u8',
            formatHint: 'HLS',
            pass: true,
            manifestPolicyPass: true,
            avcManifestPresent: true,
            hevcManifestPresent: true,
            av1ManifestPresent: false,
            avcDeviceSupported: true,
            hevcDeviceSupported: true,
            av1DeviceSupported: false,
            avcHardwareSafe: true,
            hevcHardwareSafe: true,
            av1HardwareSafe: false,
            preferredCodecFamily: 'hevc',
            fallbackCodecFamily: 'avc',
            safeCodecFamilies: ['hevc', 'avc'],
            riskyCodecFamilies: [],
            warnings: ['entry_warn_1'],
            renditionCount: 4,
            lowestBandwidth: 800000,
            highestBandwidth: 4000000,
            decision: 'prefer_hevc_hardware',
            raw: 'raw_entry_1',
            manifestValidation: {},
            diagnostics: {},
          ),
          VGStreamingCompatibilityDecisionEntry(
            key: 'stream_2',
            uri: 'https://example.com/stream2.m3u8',
            formatHint: 'HLS',
            pass: true,
            manifestPolicyPass: true,
            avcManifestPresent: true,
            hevcManifestPresent: false,
            av1ManifestPresent: false,
            avcDeviceSupported: true,
            hevcDeviceSupported: true,
            av1DeviceSupported: false,
            avcHardwareSafe: true,
            hevcHardwareSafe: true,
            av1HardwareSafe: false,
            preferredCodecFamily: 'avc',
            fallbackCodecFamily: 'avc',
            safeCodecFamilies: ['avc'],
            riskyCodecFamilies: [],
            warnings: [],
            renditionCount: 3,
            lowestBandwidth: 400000,
            highestBandwidth: 2000000,
            decision: 'prefer_avc_fallback',
            raw: 'raw_entry_2',
            manifestValidation: {},
            diagnostics: {},
          ),
        ];

    return VGStreamingCompatibilityDecisionReport(
      pass: pass,
      phase: phase,
      totalReports: totalReports,
      passedReports: passedReports,
      failedReports: failedReports,
      codecProbePass: codecProbePass,
      avcSupported: avcSupported,
      hevcSupported: hevcSupported,
      av1Supported: av1Supported,
      av1HardwareSafe: av1HardwareSafe,
      deviceWarnings: deviceWarnings,
      serverLadderPolicy: serverLadderPolicy,
      iosMirrorNote: iosMirrorNote,
      reports: defaultReports,
      raw: 'raw_compat',
      diagnostics: const <String, Object?>{'compat_key': 'val'},
    );
  }

  VGStreamingPreflightReport createPreflightReport({
    bool pass = true,
    String phase = 'Phase4C5G',
    String advisoryDecision = 'advise_stable',
    String requestedNetworkProfile = 'AUTO',
    String recommendedNetworkProfile = 'STABLE',
    Map<String, Object?> recommendedNetworkPolicy = const {},
    int totalReports = 2,
    int passedReports = 2,
    int failedReports = 0,
    List<String> warnings = const ['preflight_warn_1'],
    List<String> deviceWarnings = const [
      'device_warn_1',
    ], // to test deduplication
    bool llHlsAvailable = true,
    bool advisoryOnly = true,
    bool playbackMutation = false,
    String serverLadderPolicy = 'preflight_policy',
    String iosMirrorNote = 'preflight_note',
  }) {
    return VGStreamingPreflightReport(
      pass: pass,
      phase: phase,
      advisoryDecision: advisoryDecision,
      requestedNetworkProfile: requestedNetworkProfile,
      recommendedNetworkProfile: recommendedNetworkProfile,
      recommendedNetworkPolicy: recommendedNetworkPolicy,
      totalReports: totalReports,
      passedReports: passedReports,
      failedReports: failedReports,
      warnings: warnings,
      deviceWarnings: deviceWarnings,
      llHlsAvailable: llHlsAvailable,
      advisoryOnly: advisoryOnly,
      playbackMutation: playbackMutation,
      serverLadderPolicy: serverLadderPolicy,
      iosMirrorNote: iosMirrorNote,
      raw: 'raw_preflight',
      diagnostics: const <String, Object?>{'preflight_key': 'val'},
    );
  }

  group('VGStreamingPreflightCompositeEvaluator', () {
    test(
      '1. all inputs pass with optional preflight report and derived maps/diagnostics',
      () {
        final manifestReport = createManifestReport();
        final codecReport = createCodecReport();
        final compatibilityReport = createCompatibilityReport();
        final preflightReport = createPreflightReport();

        final evaluation = VGStreamingPreflightCompositeEvaluator.evaluate(
          manifestReport: manifestReport,
          codecReport: codecReport,
          compatibilityReport: compatibilityReport,
          preflightReport: preflightReport,
        );

        expect(evaluation.pass, isTrue);
        expect(evaluation.blocked, isFalse);
        expect(evaluation.status, 'evaluation_passed');
        expect(evaluation.avcBaselinePass, isTrue);
        expect(evaluation.serverLadderPolicyPass, isTrue);
        expect(evaluation.serverLadderPolicy, 'preflight_policy');
        expect(evaluation.iosMirrorNote, 'preflight_note');
        expect(evaluation.advisoryOnly, isTrue);
        expect(evaluation.playbackMutation, isFalse);
        expect(evaluation.totalStreamsEvaluated, 2);
        expect(evaluation.passedStreams, 2);
        expect(evaluation.failedStreams, 0);

        expect(evaluation.preferredCodecs, {
          'stream_1': 'hevc',
          'stream_2': 'avc',
        });
        expect(evaluation.fallbackCodecs, {
          'stream_1': 'avc',
          'stream_2': 'avc',
        });
        expect(evaluation.streamDecisions, {
          'stream_1': 'prefer_hevc_hardware',
          'stream_2': 'prefer_avc_fallback',
        });

        expect(evaluation.diagnostics['status'], 'evaluation_passed');
        expect(evaluation.diagnostics['pass'], isTrue);
        expect(evaluation.diagnostics['manifestPass'], isTrue);
        expect(evaluation.diagnostics['segmentRejectionPass'], isTrue);
        expect(evaluation.diagnostics['codecPass'], isTrue);
        expect(evaluation.diagnostics['avcBaselinePass'], isTrue);
        expect(evaluation.diagnostics['compatibilityPass'], isTrue);
        expect(evaluation.diagnostics['preflightPass'], isTrue);
        expect(evaluation.diagnostics['serverLadderPolicyPass'], isTrue);
        expect(evaluation.diagnostics['totalStreamsEvaluated'], 2);
        expect(evaluation.diagnostics['passedStreams'], 2);
        expect(evaluation.diagnostics['failedStreams'], 0);
        expect(
          evaluation.diagnostics['warningCount'],
          evaluation.warnings.length,
        );
        expect(evaluation.diagnostics['preferredCodecCount'], 2);
        expect(evaluation.diagnostics['fallbackCodecCount'], 2);
        expect(evaluation.diagnostics['streamDecisionCount'], 2);

        expect(
          evaluation.toString(),
          contains('VGStreamingPreflightCompositeEvaluation'),
        );
      },
    );

    test('2. manifest policy failure blocks', () {
      final manifestReport = createManifestReport(pass: false);
      final codecReport = createCodecReport();
      final compatibilityReport = createCompatibilityReport();

      final evaluation = VGStreamingPreflightCompositeEvaluator.evaluate(
        manifestReport: manifestReport,
        codecReport: codecReport,
        compatibilityReport: compatibilityReport,
      );

      expect(evaluation.pass, isFalse);
      expect(evaluation.blocked, isTrue);
      expect(evaluation.status, 'manifest_policy_failed');
      expect(evaluation.warnings, contains('manifest_policy_failed'));

      // Segment rejection failure
      final segFailReport = createManifestReport(
        pass: true,
        segmentRejectionPass: false,
      );
      final segEvaluation = VGStreamingPreflightCompositeEvaluator.evaluate(
        manifestReport: segFailReport,
        codecReport: codecReport,
        compatibilityReport: compatibilityReport,
      );
      expect(segEvaluation.pass, isFalse);
      expect(segEvaluation.blocked, isTrue);
      expect(segEvaluation.status, 'manifest_policy_failed');
    });

    test('3. codec baseline AVC failure blocks', () {
      final manifestReport = createManifestReport();
      final codecReport = createCodecReport(avcPass: false);
      final compatibilityReport = createCompatibilityReport();

      final evaluation = VGStreamingPreflightCompositeEvaluator.evaluate(
        manifestReport: manifestReport,
        codecReport: codecReport,
        compatibilityReport: compatibilityReport,
      );

      expect(evaluation.pass, isFalse);
      expect(evaluation.blocked, isTrue);
      expect(evaluation.status, 'codec_capability_failed');
      expect(evaluation.warnings, contains('codec_capability_failed'));

      // Also if avcSupported is false
      final noAvcSupported = createCodecReport(avcSupported: false);
      final eval2 = VGStreamingPreflightCompositeEvaluator.evaluate(
        manifestReport: manifestReport,
        codecReport: noAvcSupported,
        compatibilityReport: compatibilityReport,
      );
      expect(eval2.pass, isFalse);
      expect(eval2.status, 'codec_capability_failed');
    });

    test('4. compatibility decision failure blocks', () {
      final manifestReport = createManifestReport();
      final codecReport = createCodecReport();
      final compatibilityReport = createCompatibilityReport(
        pass: false,
        failedReports: 1,
        passedReports: 1,
      );

      final evaluation = VGStreamingPreflightCompositeEvaluator.evaluate(
        manifestReport: manifestReport,
        codecReport: codecReport,
        compatibilityReport: compatibilityReport,
      );

      expect(evaluation.pass, isFalse);
      expect(evaluation.blocked, isTrue);
      expect(evaluation.status, 'compatibility_decision_failed');
      expect(evaluation.warnings, contains('compatibility_decision_failed'));
      expect(evaluation.failedStreams, 1);
    });

    test('5. optional preflight failure blocks', () {
      final manifestReport = createManifestReport();
      final codecReport = createCodecReport();
      final compatibilityReport = createCompatibilityReport();
      final preflightReport = createPreflightReport(pass: false);

      final evaluation = VGStreamingPreflightCompositeEvaluator.evaluate(
        manifestReport: manifestReport,
        codecReport: codecReport,
        compatibilityReport: compatibilityReport,
        preflightReport: preflightReport,
      );

      expect(evaluation.pass, isFalse);
      expect(evaluation.blocked, isTrue);
      expect(evaluation.status, 'preflight_report_failed');
      expect(evaluation.warnings, contains('preflight_report_failed'));
    });

    test(
      '6. advisory invariant rejection for non-advisory/mutating preflight',
      () {
        final manifestReport = createManifestReport();
        final codecReport = createCodecReport();
        final compatibilityReport = createCompatibilityReport();

        // non-advisory
        final nonAdvisory = createPreflightReport(advisoryOnly: false);
        final eval1 = VGStreamingPreflightCompositeEvaluator.evaluate(
          manifestReport: manifestReport,
          codecReport: codecReport,
          compatibilityReport: compatibilityReport,
          preflightReport: nonAdvisory,
        );
        expect(eval1.pass, isFalse);
        expect(eval1.status, 'advisory_invariant_violated');
        expect(eval1.warnings, contains('advisory_invariant_violated'));

        // mutating
        final mutating = createPreflightReport(playbackMutation: true);
        final eval2 = VGStreamingPreflightCompositeEvaluator.evaluate(
          manifestReport: manifestReport,
          codecReport: codecReport,
          compatibilityReport: compatibilityReport,
          preflightReport: mutating,
        );
        expect(eval2.pass, isFalse);
        expect(eval2.status, 'advisory_invariant_violated');
        expect(eval2.warnings, contains('advisory_invariant_violated'));
      },
    );

    test('7. deterministic warning merge and dedupe', () {
      final manifestReport = createManifestReport();
      final codecReport = createCodecReport();
      final compatibilityReport = createCompatibilityReport(
        deviceWarnings: const ['warn_A', 'warn_B'],
        reports: const [
          VGStreamingCompatibilityDecisionEntry(
            key: 'stream_1',
            uri: 'https://example.com/stream1.m3u8',
            formatHint: 'HLS',
            pass: true,
            manifestPolicyPass: true,
            avcManifestPresent: true,
            hevcManifestPresent: true,
            av1ManifestPresent: false,
            avcDeviceSupported: true,
            hevcDeviceSupported: true,
            av1DeviceSupported: false,
            avcHardwareSafe: true,
            hevcHardwareSafe: true,
            av1HardwareSafe: false,
            preferredCodecFamily: 'hevc',
            fallbackCodecFamily: 'avc',
            safeCodecFamilies: ['hevc'],
            riskyCodecFamilies: [],
            warnings: ['warn_B', 'warn_C'],
            renditionCount: 2,
            lowestBandwidth: 500,
            highestBandwidth: 1000,
            decision: 'prefer_hevc_hardware',
            raw: '',
            manifestValidation: {},
            diagnostics: {},
          ),
        ],
      );
      final preflightReport = createPreflightReport(
        warnings: const ['warn_C', 'warn_D'],
        deviceWarnings: const ['warn_A', 'warn_E'],
      );

      final evaluation = VGStreamingPreflightCompositeEvaluator.evaluate(
        manifestReport: manifestReport,
        codecReport: codecReport,
        compatibilityReport: compatibilityReport,
        preflightReport: preflightReport,
      );

      expect(
        evaluation.warnings,
        equals(['warn_A', 'warn_B', 'warn_C', 'warn_D', 'warn_E']),
      );
    });

    test('8. unsupported report produces unsupported_platform', () {
      final manifestReport =
          VGStreamingManifestPolicyValidationReport.unsupported();
      final codecReport = createCodecReport();
      final compatibilityReport = createCompatibilityReport();

      final evaluation = VGStreamingPreflightCompositeEvaluator.evaluate(
        manifestReport: manifestReport,
        codecReport: codecReport,
        compatibilityReport: compatibilityReport,
      );

      expect(evaluation.pass, isFalse);
      expect(evaluation.status, 'unsupported_platform');
      expect(evaluation.warnings, contains('unsupported_platform'));
    });

    test('9. immutable collections cannot be mutated', () {
      final manifestReport = createManifestReport();
      final codecReport = createCodecReport();
      final compatibilityReport = createCompatibilityReport();

      final evaluation = VGStreamingPreflightCompositeEvaluator.evaluate(
        manifestReport: manifestReport,
        codecReport: codecReport,
        compatibilityReport: compatibilityReport,
      );

      expect(() => evaluation.warnings.add('new_warn'), throwsUnsupportedError);
      expect(
        () => evaluation.preferredCodecs['foo'] = 'bar',
        throwsUnsupportedError,
      );
      expect(
        () => evaluation.fallbackCodecs['foo'] = 'bar',
        throwsUnsupportedError,
      );
      expect(
        () => evaluation.streamDecisions['foo'] = 'bar',
        throwsUnsupportedError,
      );
      expect(
        () => evaluation.diagnostics['foo'] = 'bar',
        throwsUnsupportedError,
      );
    });

    test('10. fallback values and getters without preflight report', () {
      final manifestReport = createManifestReport(
        serverLadderPolicy: 'manifest_p',
        iosMirrorNote: 'manifest_n',
      );
      final codecReport = createCodecReport(
        serverLadderPolicy: '',
        iosMirrorNote: '',
      );
      final compatibilityReport = createCompatibilityReport(
        serverLadderPolicy: '',
        iosMirrorNote: '',
      );

      final evaluation = VGStreamingPreflightCompositeEvaluator.evaluate(
        manifestReport: manifestReport,
        codecReport: codecReport,
        compatibilityReport: compatibilityReport,
      );

      expect(evaluation.pass, isTrue);
      expect(evaluation.advisoryOnly, isTrue);
      expect(evaluation.playbackMutation, isFalse);
      expect(evaluation.preflightReport, isNull);
      expect(evaluation.serverLadderPolicy, 'manifest_p');
      expect(evaluation.iosMirrorNote, 'manifest_n');
    });
  });
}
