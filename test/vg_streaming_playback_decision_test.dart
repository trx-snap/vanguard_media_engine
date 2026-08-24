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

    group('Client Capabilities in Decision Planner', () {
      test(
        'plan with Apple AVPlayer capabilities and preferDash produces playback_ready with HLS, not DASH',
        () {
          final request = VGStreamingPlaybackDecisionRequest(
            sourceSet: sourceSet,
            preflightReport: validReport,
            preference: VGStreamingSourceSelectionPreference.preferDash,
            clientCapabilities:
                const VGStreamingSourceClientCapabilities.appleAvPlayer(),
          );

          final decision = VGStreamingPlaybackDecisionPlanner.plan(request);

          expect(decision.canOpenPlayback, isTrue);
          expect(decision.decision, equals('playback_ready'));
          expect(decision.selectedKey, equals('hls_main'));
          expect(decision.selectedSource, equals(hlsSource));
          expect(
            decision.playbackOptions?.formatHint,
            equals(VGStreamingFormatHint.hls),
          );
          expect(
            decision.playbackOptions?.uri,
            equals(Uri.parse('https://example.com/main.m3u8')),
          );
          expect(
            decision.warnings,
            contains('source_incompatible:dash_main:dash_not_supported'),
          );
          expect(decision.diagnostics['clientType'], equals('apple_avplayer'));
        },
      );

      test(
        'planFromComposite passes clientCapabilities through on pass path',
        () {
          final compositePass = VGStreamingPreflightCompositeEvaluation(
            pass: true,
            status: 'composite_pass',
            avcBaselinePass: true,
            serverLadderPolicyPass: true,
            serverLadderPolicy: '',
            iosMirrorNote: '',
            warnings: const [],
            preferredCodecs: const {},
            fallbackCodecs: const {},
            streamDecisions: const {},
            totalStreamsEvaluated: 1,
            passedStreams: 1,
            failedStreams: 0,
            manifestReport: const VGStreamingManifestPolicyValidationReport(
              pass: true,
              phase: 'Phase4C5D',
              totalManifestsValidated: 1,
              passedManifests: 1,
              failedManifests: 0,
              segmentRejectionPass: true,
              serverLadderPolicy: '',
              iosMirrorNote: '',
              results: [],
              segmentRejectionResult: {},
              raw: '',
              diagnostics: {},
            ),
            codecReport: const VGStreamingCodecCapabilityReport(
              pass: true,
              phase: 'Phase4C5A',
              avcPass: true,
              codecCountPass: true,
              fallbackPolicyPass: true,
              iosMirrorNotePass: true,
              avcSupported: true,
              hevcSupported: true,
              av1Supported: false,
              androidSdk: 34,
              serverLadderPolicy: '',
              iosMirrorNote: '',
              codecs: [],
              probe: {},
              raw: '',
              diagnostics: {},
            ),
            compatibilityReport: const VGStreamingCompatibilityDecisionReport(
              pass: true,
              phase: 'Phase4C5E',
              totalReports: 1,
              passedReports: 1,
              failedReports: 0,
              codecProbePass: true,
              avcSupported: true,
              hevcSupported: true,
              av1Supported: false,
              av1HardwareSafe: false,
              deviceWarnings: [],
              serverLadderPolicy: '',
              iosMirrorNote: '',
              reports: [],
              raw: '',
              diagnostics: {},
            ),
            diagnostics: const {},
          );

          final request = VGStreamingPlaybackCompositeDecisionRequest(
            sourceSet: sourceSet,
            preflightReport: validReport,
            compositeEvaluation: compositePass,
            preference: VGStreamingSourceSelectionPreference.preferDash,
            clientCapabilities:
                const VGStreamingSourceClientCapabilities.appleAvPlayer(),
          );

          final decision = VGStreamingPlaybackDecisionPlanner.planFromComposite(
            request,
          );

          expect(decision.canOpenPlayback, isTrue);
          expect(decision.decision, equals('playback_ready'));
          expect(decision.selectedKey, equals('hls_main'));
          expect(decision.selectedSource, equals(hlsSource));
          expect(
            decision.playbackOptions?.formatHint,
            equals(VGStreamingFormatHint.hls),
          );
          expect(
            decision.warnings,
            contains('source_incompatible:dash_main:dash_not_supported'),
          );
          expect(decision.diagnostics['clientType'], equals('apple_avplayer'));
        },
      );

      test(
        'planFromComposite passes clientCapabilities to diagnostics on block path',
        () {
          final compositeBlock = VGStreamingPreflightCompositeEvaluation(
            pass: false,
            status: 'codec_unsupported',
            avcBaselinePass: false,
            serverLadderPolicyPass: false,
            serverLadderPolicy: '',
            iosMirrorNote: '',
            warnings: const ['codec_unsupported'],
            preferredCodecs: const {},
            fallbackCodecs: const {},
            streamDecisions: const {},
            totalStreamsEvaluated: 1,
            passedStreams: 0,
            failedStreams: 1,
            manifestReport: const VGStreamingManifestPolicyValidationReport(
              pass: true,
              phase: 'Phase4C5D',
              totalManifestsValidated: 1,
              passedManifests: 1,
              failedManifests: 0,
              segmentRejectionPass: true,
              serverLadderPolicy: '',
              iosMirrorNote: '',
              results: [],
              segmentRejectionResult: {},
              raw: '',
              diagnostics: {},
            ),
            codecReport: const VGStreamingCodecCapabilityReport(
              pass: false,
              phase: 'Phase4C5A',
              avcPass: false,
              codecCountPass: true,
              fallbackPolicyPass: true,
              iosMirrorNotePass: true,
              avcSupported: false,
              hevcSupported: false,
              av1Supported: false,
              androidSdk: 34,
              serverLadderPolicy: '',
              iosMirrorNote: '',
              codecs: [],
              probe: {},
              raw: '',
              diagnostics: {},
            ),
            compatibilityReport: const VGStreamingCompatibilityDecisionReport(
              pass: false,
              phase: 'Phase4C5E',
              totalReports: 1,
              passedReports: 0,
              failedReports: 1,
              codecProbePass: false,
              avcSupported: false,
              hevcSupported: false,
              av1Supported: false,
              av1HardwareSafe: false,
              deviceWarnings: [],
              serverLadderPolicy: '',
              iosMirrorNote: '',
              reports: [],
              raw: '',
              diagnostics: {},
            ),
            diagnostics: const {},
          );

          final request = VGStreamingPlaybackCompositeDecisionRequest(
            sourceSet: sourceSet,
            preflightReport: validReport,
            compositeEvaluation: compositeBlock,
            preference: VGStreamingSourceSelectionPreference.preferDash,
            clientCapabilities:
                const VGStreamingSourceClientCapabilities.appleAvPlayer(),
          );

          final decision = VGStreamingPlaybackDecisionPlanner.planFromComposite(
            request,
          );

          expect(decision.canOpenPlayback, isFalse);
          expect(
            decision.decision,
            equals('composite_preflight_blocked:codec_unsupported'),
          );
          expect(decision.diagnostics['clientType'], equals('apple_avplayer'));
        },
      );
    });
  });
}
