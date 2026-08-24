// Copyright (c) Connects — Vanguard Phase 4C7M.
// Public streaming playback decision planner unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackDecisionPlanner', () {
    final hlsSource = VGStreamingSourceDescriptor(
      key: 'hls_main',
      uri: Uri.parse('https://example.com/main.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
      httpHeaders: {'Authorization': 'Bearer test_token'},
      requireAdaptiveLadder: true,
      requireAvcFallback: true,
      requireLlHlsTags: false,
      cacheOptions: const VGPlaybackCacheOptions(
        cacheEnabled: true,
        cacheMaxBytes: 50 * 1024 * 1024,
      ),
      autoPlay: true,
      initialPositionMs: 1500,
    );

    final dashSource = VGStreamingSourceDescriptor(
      key: 'dash_main',
      uri: Uri.parse('https://example.com/main.mpd'),
      initialWidth: 1280,
      initialHeight: 720,
      formatHint: VGStreamingFormatHint.dash,
      requireAdaptiveLadder: true,
      requireAvcFallback: false,
      requireLlHlsTags: false,
      autoPlay: false,
      initialPositionMs: 0,
    );

    final llHlsSource = VGStreamingSourceDescriptor(
      key: 'll_hls_main',
      uri: Uri.parse('https://example.com/ll_stream.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
      requireAdaptiveLadder: true,
      requireAvcFallback: true,
      requireLlHlsTags: true,
      autoPlay: true,
    );

    final sourceSet = VGStreamingSourceSet(
      sources: [hlsSource, dashSource, llHlsSource],
    );

    const validReport = VGStreamingPreflightReport(
      pass: true,
      phase: 'Phase4C5G',
      advisoryDecision: 'preflight_passed',
      requestedNetworkProfile: 'STABLE',
      recommendedNetworkProfile: 'STABLE',
      recommendedNetworkPolicy: <String, Object?>{'profile': 'STABLE'},
      totalReports: 3,
      passedReports: 3,
      failedReports: 0,
      warnings: <String>[],
      deviceWarnings: <String>[],
      llHlsAvailable: true,
      advisoryOnly: true,
      playbackMutation: false,
      serverLadderPolicy: '',
      iosMirrorNote: '',
      raw: 'status=OK',
      diagnostics: <String, Object?>{},
    );

    const blockedReport = VGStreamingPreflightReport(
      pass: false,
      phase: 'Phase4C5G',
      advisoryDecision: 'blocked_manifest_unreachable',
      requestedNetworkProfile: 'STABLE',
      recommendedNetworkProfile: 'CONSTRAINED',
      recommendedNetworkPolicy: <String, Object?>{},
      totalReports: 1,
      passedReports: 0,
      failedReports: 1,
      warnings: <String>['network_unreachable'],
      deviceWarnings: <String>[],
      llHlsAvailable: false,
      advisoryOnly: true,
      playbackMutation: false,
      serverLadderPolicy: '',
      iosMirrorNote: '',
      raw: 'status=ERROR',
      diagnostics: <String, Object?>{},
    );

    test(
      'successful plan produces canOpenPlayback == true and playback_ready',
      () {
        final request = VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: validReport,
          preference: VGStreamingSourceSelectionPreference.preserveOrder,
        );

        final decision = VGStreamingPlaybackDecisionPlanner.plan(request);

        expect(decision.canOpenPlayback, isTrue);
        expect(decision.decision, equals('playback_ready'));
        expect(decision.selectedKey, equals('hls_main'));
        expect(decision.selectedSource, equals(hlsSource));
        expect(decision.playbackOptions, isNotNull);

        final options = decision.playbackOptions!;
        expect(options.uri, equals(Uri.parse('https://example.com/main.m3u8')));
        expect(options.formatHint, equals(VGStreamingFormatHint.hls));
        expect(options.initialWidth, equals(1920));
        expect(options.initialHeight, equals(1080));
        expect(
          options.httpHeaders,
          equals({'Authorization': 'Bearer test_token'}),
        );
        expect(options.autoPlay, isTrue);
        expect(options.initialPositionMs, equals(1500));
        expect(options.cacheOptions?.cacheEnabled, isTrue);
        expect(
          options.networkProfile,
          equals(VGStreamingNetworkProfile.stable),
        );

        expect(decision.diagnostics['preflightPhase'], equals('Phase4C5G'));
        expect(decision.diagnostics['preflightPass'], isTrue);
        expect(
          decision.diagnostics['startupReason'],
          equals('preflight_passed'),
        );
        expect(
          decision.diagnostics['selectionDecision'],
          equals('source_selected'),
        );
        expect(decision.diagnostics['preference'], equals('preserveOrder'));
        expect(decision.diagnostics['selectedKey'], equals('hls_main'));
        expect(decision.diagnostics['canOpenPlayback'], isTrue);
      },
    );

    test('failed preflight blocks playback with startup_plan_blocked', () {
      final request = VGStreamingPlaybackDecisionRequest(
        sourceSet: sourceSet,
        preflightReport: blockedReport,
        preference: VGStreamingSourceSelectionPreference.preserveOrder,
      );

      final decision = VGStreamingPlaybackDecisionPlanner.plan(request);

      expect(decision.canOpenPlayback, isFalse);
      expect(decision.decision, equals('startup_plan_blocked'));
      expect(decision.selectedKey, isNull);
      expect(decision.selectedSource, isNull);
      expect(decision.playbackOptions, isNull);
      expect(decision.warnings, contains('startup_plan_blocked'));
      expect(decision.warnings, contains('network_unreachable'));
      expect(decision.diagnostics['canOpenPlayback'], isFalse);
      expect(decision.diagnostics['preflightPass'], isFalse);
    });

    test('preferred key routes into selector and chooses exact key', () {
      final request = VGStreamingPlaybackDecisionRequest(
        sourceSet: sourceSet,
        preflightReport: validReport,
        preferredKeys: ['dash_main'],
      );

      final decision = VGStreamingPlaybackDecisionPlanner.plan(request);

      expect(decision.canOpenPlayback, isTrue);
      expect(decision.decision, equals('playback_ready'));
      expect(decision.selectedKey, equals('dash_main'));
      expect(decision.selectedSource, equals(dashSource));
      expect(
        decision.playbackOptions?.formatHint,
        equals(VGStreamingFormatHint.dash),
      );
      expect(
        decision.playbackOptions?.uri,
        equals(Uri.parse('https://example.com/main.mpd')),
      );
    });

    test('unknown preferred key warning is preserved', () {
      final request = VGStreamingPlaybackDecisionRequest(
        sourceSet: sourceSet,
        preflightReport: validReport,
        preferredKeys: ['non_existent_key', 'll_hls_main'],
      );

      final decision = VGStreamingPlaybackDecisionPlanner.plan(request);

      expect(decision.canOpenPlayback, isTrue);
      expect(decision.selectedKey, equals('ll_hls_main'));
      expect(
        decision.warnings,
        contains('unknown_preferred_key:non_existent_key'),
      );
    });

    test('preferDash and preferLowLatency are honored through selector', () {
      // preferDash
      final dashRequest = VGStreamingPlaybackDecisionRequest(
        sourceSet: sourceSet,
        preflightReport: validReport,
        preference: VGStreamingSourceSelectionPreference.preferDash,
      );
      final dashDecision = VGStreamingPlaybackDecisionPlanner.plan(dashRequest);
      expect(dashDecision.canOpenPlayback, isTrue);
      expect(dashDecision.selectedKey, equals('dash_main'));

      // preferLowLatency
      final llRequest = VGStreamingPlaybackDecisionRequest(
        sourceSet: sourceSet,
        preflightReport: validReport,
        preference: VGStreamingSourceSelectionPreference.preferLowLatency,
      );
      final llDecision = VGStreamingPlaybackDecisionPlanner.plan(llRequest);
      expect(llDecision.canOpenPlayback, isTrue);
      expect(llDecision.selectedKey, equals('ll_hls_main'));
    });

    test(
      'warnings are combined without mutating original plan/selection inputs',
      () {
        const reportWithWarning = VGStreamingPreflightReport(
          pass: true,
          phase: 'Phase4C5G',
          advisoryDecision: 'preflight_passed',
          requestedNetworkProfile: 'STABLE',
          recommendedNetworkProfile: 'STABLE',
          recommendedNetworkPolicy: <String, Object?>{},
          totalReports: 1,
          passedReports: 1,
          failedReports: 0,
          warnings: <String>['device_low_power_mode'],
          deviceWarnings: <String>[],
          llHlsAvailable: true,
          advisoryOnly: true,
          playbackMutation: false,
          serverLadderPolicy: '',
          iosMirrorNote: '',
          raw: 'status=OK',
          diagnostics: <String, Object?>{},
        );

        final request = VGStreamingPlaybackDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: reportWithWarning,
          preferredKeys: ['unknown_key', 'dash_main'],
        );

        final decision = VGStreamingPlaybackDecisionPlanner.plan(request);

        expect(decision.warnings, contains('device_low_power_mode'));
        expect(
          decision.warnings,
          contains('unknown_preferred_key:unknown_key'),
        );

        // Check plan and selection warnings are intact and unmodifiable
        expect(
          decision.startupPlan.warnings,
          contains('device_low_power_mode'),
        );
        expect(
          decision.startupPlan.warnings,
          isNot(contains('unknown_preferred_key:unknown_key')),
        );
        expect(
          decision.selection.warnings,
          contains('unknown_preferred_key:unknown_key'),
        );
        expect(
          decision.selection.warnings,
          isNot(contains('device_low_power_mode')),
        );
      },
    );

    test('toString formats decision request and decision cleanly', () {
      final request = VGStreamingPlaybackDecisionRequest(
        sourceSet: sourceSet,
        preflightReport: validReport,
        preferredKeys: ['dash_main'],
      );
      expect(request.toString(), contains('preferredKeys=[dash_main]'));

      final decision = VGStreamingPlaybackDecisionPlanner.plan(request);
      expect(decision.toString(), contains('canOpenPlayback=true'));
      expect(decision.toString(), contains('selectedKey=dash_main'));
      expect(decision.toString(), contains('decision=playback_ready'));
    });

    group('planFromComposite', () {
      VGStreamingManifestPolicyValidationReport createManifestReport({
        bool pass = true,
        String phase = 'Phase4C5D',
        bool segmentRejectionPass = true,
        String serverLadderPolicy =
            'add_hevc_av1_renditions_but_keep_avc_fallback',
        String iosMirrorNote = 'manifest_note',
      }) {
        return VGStreamingManifestPolicyValidationReport(
          pass: pass,
          phase: phase,
          totalManifestsValidated: 1,
          passedManifests: pass ? 1 : 0,
          failedManifests: pass ? 0 : 1,
          segmentRejectionPass: segmentRejectionPass,
          serverLadderPolicy: serverLadderPolicy,
          iosMirrorNote: iosMirrorNote,
          results: const [],
          segmentRejectionResult: const {},
          raw: 'raw_manifest',
          diagnostics: const {},
        );
      }

      VGStreamingCodecCapabilityReport createCodecReport({
        bool pass = true,
        String phase = 'Phase4C5A',
        bool avcPass = true,
        bool avcSupported = true,
        bool hevcSupported = true,
        bool fallbackPolicyPass = true,
        String serverLadderPolicy =
            'add_hevc_av1_renditions_but_keep_avc_fallback',
        String iosMirrorNote = 'codec_note',
      }) {
        return VGStreamingCodecCapabilityReport(
          pass: pass,
          phase: phase,
          avcPass: avcPass,
          codecCountPass: true,
          fallbackPolicyPass: fallbackPolicyPass,
          iosMirrorNotePass: true,
          avcSupported: avcSupported,
          hevcSupported: hevcSupported,
          av1Supported: false,
          androidSdk: 34,
          serverLadderPolicy: serverLadderPolicy,
          iosMirrorNote: iosMirrorNote,
          codecs: const [],
          probe: const {},
          raw: 'raw_codec',
          diagnostics: const {},
        );
      }

      VGStreamingCompatibilityDecisionReport createCompatibilityReport({
        bool pass = true,
        String phase = 'Phase4C5E',
        int totalReports = 1,
        int passedReports = 1,
        int failedReports = 0,
        bool avcSupported = true,
        List<String> deviceWarnings = const ['device_compat_warning'],
        List<VGStreamingCompatibilityDecisionEntry>? reports,
      }) {
        final defaultReports =
            reports ??
            const [
              VGStreamingCompatibilityDecisionEntry(
                key: 'hls_main',
                uri: 'https://example.com/main.m3u8',
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
                preferredCodecFamily: 'HEVC',
                fallbackCodecFamily: 'AVC',
                safeCodecFamilies: ['HEVC', 'AVC'],
                riskyCodecFamilies: [],
                renditionCount: 3,
                lowestBandwidth: 800000,
                highestBandwidth: 5000000,
                decision: 'prefer_hevc_hardware',
                warnings: ['stream_entry_warning'],
                raw: 'raw_entry',
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
          codecProbePass: true,
          avcSupported: avcSupported,
          hevcSupported: true,
          av1Supported: false,
          av1HardwareSafe: false,
          serverLadderPolicy: 'add_hevc_av1_renditions_but_keep_avc_fallback',
          iosMirrorNote: 'compat_note',
          deviceWarnings: deviceWarnings,
          reports: defaultReports,
          raw: 'raw_compat',
          diagnostics: const {},
        );
      }

      test('composite pass delegates to normal decision planning', () {
        final composite = VGStreamingPreflightCompositeEvaluator.evaluate(
          manifestReport: createManifestReport(),
          codecReport: createCodecReport(),
          compatibilityReport: createCompatibilityReport(),
          preflightReport: validReport,
        );

        final request = VGStreamingPlaybackCompositeDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: validReport,
          compositeEvaluation: composite,
          preference: VGStreamingSourceSelectionPreference.preserveOrder,
        );

        final decision = VGStreamingPlaybackDecisionPlanner.planFromComposite(
          request,
        );

        expect(decision.canOpenPlayback, isTrue);
        expect(decision.decision, equals('playback_ready'));
        expect(decision.selectedKey, equals('hls_main'));
        expect(decision.selectedSource, equals(hlsSource));
        expect(decision.playbackOptions, isNotNull);

        // Check composite diagnostics
        expect(
          decision.diagnostics['compositeStatus'],
          equals('evaluation_passed'),
        );
        expect(decision.diagnostics['compositePass'], isTrue);
        expect(decision.diagnostics['compositeAdvisoryOnly'], isTrue);
        expect(decision.diagnostics['compositePlaybackMutation'], isFalse);
        expect(decision.diagnostics['compositeAvcBaselinePass'], isTrue);
        expect(decision.diagnostics['compositeServerLadderPolicyPass'], isTrue);
        expect(
          decision.diagnostics['compositeTotalStreamsEvaluated'],
          equals(1),
        );
        expect(decision.diagnostics['compositePassedStreams'], equals(1));
        expect(decision.diagnostics['compositeFailedStreams'], equals(0));
        expect(decision.diagnostics['canOpenPlayback'], isTrue);

        // Check warnings include composite warnings
        expect(decision.warnings, contains('device_compat_warning'));
        expect(decision.warnings, contains('stream_entry_warning'));
      });

      test(
        'composite failure blocks even when normal preflight report passes',
        () {
          // Manifest policy failure causes composite to fail
          final composite = VGStreamingPreflightCompositeEvaluator.evaluate(
            manifestReport: createManifestReport(
              pass: false,
              segmentRejectionPass: false,
            ),
            codecReport: createCodecReport(),
            compatibilityReport: createCompatibilityReport(),
            preflightReport: validReport,
          );

          expect(composite.pass, isFalse);
          expect(composite.status, equals('manifest_policy_failed'));

          final request = VGStreamingPlaybackCompositeDecisionRequest(
            sourceSet: sourceSet,
            preflightReport: validReport,
            compositeEvaluation: composite,
          );

          final decision = VGStreamingPlaybackDecisionPlanner.planFromComposite(
            request,
          );

          expect(decision.canOpenPlayback, isFalse);
          expect(
            decision.decision,
            equals('composite_preflight_blocked:manifest_policy_failed'),
          );
          expect(decision.selectedKey, isNull);
          expect(decision.selectedSource, isNull);
          expect(decision.playbackOptions, isNull);
          expect(decision.selection.selected, isFalse);
          expect(
            decision.selection.decision,
            equals('composite_preflight_blocked:manifest_policy_failed'),
          );

          // Warnings deduped in encounter order
          expect(
            decision.warnings,
            contains('composite_preflight_blocked:manifest_policy_failed'),
          );
          expect(decision.warnings, contains('manifest_policy_failed'));

          // Diagnostics
          expect(
            decision.diagnostics['compositeStatus'],
            equals('manifest_policy_failed'),
          );
          expect(decision.diagnostics['compositePass'], isFalse);
          expect(decision.diagnostics['compositeAdvisoryOnly'], isTrue);
          expect(decision.diagnostics['compositePlaybackMutation'], isFalse);
          expect(decision.diagnostics['canOpenPlayback'], isFalse);
        },
      );

      test(
        'composite advisory invariant violation blocks and exposes diagnostics',
        () {
          const mutatedReport = VGStreamingPreflightReport(
            pass: true,
            phase: 'Phase4C5G',
            advisoryDecision: 'preflight_passed',
            requestedNetworkProfile: 'STABLE',
            recommendedNetworkProfile: 'STABLE',
            recommendedNetworkPolicy: <String, Object?>{},
            totalReports: 1,
            passedReports: 1,
            failedReports: 0,
            warnings: <String>[],
            deviceWarnings: <String>[],
            llHlsAvailable: true,
            advisoryOnly: false, // Invariant violation
            playbackMutation: true, // Invariant violation
            serverLadderPolicy: '',
            iosMirrorNote: '',
            raw: 'status=OK',
            diagnostics: <String, Object?>{},
          );

          final composite = VGStreamingPreflightCompositeEvaluator.evaluate(
            manifestReport: createManifestReport(),
            codecReport: createCodecReport(),
            compatibilityReport: createCompatibilityReport(),
            preflightReport: mutatedReport,
          );

          expect(composite.pass, isFalse);
          expect(composite.status, equals('advisory_invariant_violated'));

          final request = VGStreamingPlaybackCompositeDecisionRequest(
            sourceSet: sourceSet,
            preflightReport: mutatedReport,
            compositeEvaluation: composite,
          );

          final decision = VGStreamingPlaybackDecisionPlanner.planFromComposite(
            request,
          );

          expect(decision.canOpenPlayback, isFalse);
          expect(
            decision.decision,
            equals('composite_preflight_blocked:advisory_invariant_violated'),
          );
          expect(decision.diagnostics['compositeAdvisoryOnly'], isFalse);
          expect(decision.diagnostics['compositePlaybackMutation'], isTrue);
          expect(decision.diagnostics['compositePass'], isFalse);
          expect(decision.diagnostics['canOpenPlayback'], isFalse);
        },
      );

      test(
        'composite pass with failed underlying preflight remains blocked by startup plan',
        () {
          final composite = VGStreamingPreflightCompositeEvaluator.evaluate(
            manifestReport: createManifestReport(),
            codecReport: createCodecReport(),
            compatibilityReport: createCompatibilityReport(),
            // Passing preflight at composite level (preflightReport: null or valid report for composite)
          );

          expect(composite.pass, isTrue);

          // Request has blocked preflight report
          final request = VGStreamingPlaybackCompositeDecisionRequest(
            sourceSet: sourceSet,
            preflightReport: blockedReport,
            compositeEvaluation: composite,
          );

          final decision = VGStreamingPlaybackDecisionPlanner.planFromComposite(
            request,
          );

          expect(decision.canOpenPlayback, isFalse);
          expect(decision.decision, equals('startup_plan_blocked'));
          expect(decision.selectedKey, isNull);
          expect(decision.selectedSource, isNull);
          expect(decision.playbackOptions, isNull);
          expect(decision.warnings, contains('startup_plan_blocked'));
          expect(decision.warnings, contains('network_unreachable'));
          expect(decision.diagnostics['canOpenPlayback'], isFalse);
          expect(decision.diagnostics['preflightPass'], isFalse);
          expect(decision.diagnostics['compositePass'], isTrue);
          expect(
            decision.diagnostics['compositeStatus'],
            equals('evaluation_passed'),
          );
        },
      );

      test('toString formats composite decision request cleanly', () {
        final composite = VGStreamingPreflightCompositeEvaluator.evaluate(
          manifestReport: createManifestReport(),
          codecReport: createCodecReport(),
          compatibilityReport: createCompatibilityReport(),
          preflightReport: validReport,
        );

        final request = VGStreamingPlaybackCompositeDecisionRequest(
          sourceSet: sourceSet,
          preflightReport: validReport,
          compositeEvaluation: composite,
          preferredKeys: ['hls_main'],
        );

        expect(
          request.toString(),
          contains('VGStreamingPlaybackCompositeDecisionRequest'),
        );
        expect(
          request.toString(),
          contains('compositeStatus=evaluation_passed'),
        );
        expect(request.toString(), contains('preferredKeys=[hls_main]'));
      });
    });
  });
}
