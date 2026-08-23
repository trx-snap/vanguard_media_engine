// Copyright (c) Connects — Vanguard Phase 4C7G.
// Public streaming startup plan helper unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingStartupPlan & Planner', () {
    test(
      'passing preflight report with CONSTRAINED produces shouldProceed=true and constrained playback options',
      () {
        const report = VGStreamingPreflightReport(
          pass: true,
          phase: 'Phase4C5G',
          advisoryDecision: 'advise_constrained',
          requestedNetworkProfile: 'CONSTRAINED',
          recommendedNetworkProfile: 'CONSTRAINED',
          recommendedNetworkPolicy: <String, Object?>{'profile': 'CONSTRAINED'},
          totalReports: 1,
          passedReports: 1,
          failedReports: 0,
          warnings: <String>['minor_ladder_warning'],
          deviceWarnings: <String>['av1_software_only'],
          llHlsAvailable: false,
          advisoryOnly: true,
          playbackMutation: false,
          serverLadderPolicy: 'keep_avc_fallback',
          iosMirrorNote: '',
          raw: 'status=OK;decision=advise_constrained',
          diagnostics: <String, Object?>{},
        );

        final plan = VGStreamingStartupPlan.fromPreflight(report);

        expect(plan.shouldProceed, isTrue);
        expect(plan.reason, equals('advise_constrained'));
        expect(
          plan.recommendedNetworkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(
          plan.warnings,
          equals(['minor_ladder_warning', 'av1_software_only']),
        );
        expect(plan.preflightReport, equals(report));
        expect(plan.toString(), contains('shouldProceed=true'));

        final options = plan.buildPlaybackOptions(
          uri: Uri.parse('https://example.com/stream.m3u8'),
          initialWidth: 1280,
          initialHeight: 720,
        );

        expect(
          options.uri,
          equals(Uri.parse('https://example.com/stream.m3u8')),
        );
        expect(options.initialWidth, equals(1280));
        expect(options.initialHeight, equals(720));
        expect(
          options.networkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(options.formatHint, equals(VGStreamingFormatHint.auto));
        expect(options.autoPlay, isTrue);
        expect(options.initialPositionMs, isNull);
        expect(options.cacheOptions, isNull);
        expect(options.httpHeaders, isNull);
      },
    );

    test('passing report with LOW_LATENCY maps correctly', () {
      const report = VGStreamingPreflightReport(
        pass: true,
        phase: 'Phase4C5G',
        advisoryDecision: 'advise_low_latency',
        requestedNetworkProfile: 'LOW_LATENCY',
        recommendedNetworkProfile: 'LOW_LATENCY',
        recommendedNetworkPolicy: <String, Object?>{'profile': 'LOW_LATENCY'},
        totalReports: 1,
        passedReports: 1,
        failedReports: 0,
        warnings: <String>[],
        deviceWarnings: <String>[],
        llHlsAvailable: true,
        advisoryOnly: true,
        playbackMutation: false,
        serverLadderPolicy: '',
        iosMirrorNote: '',
        raw: 'status=OK;decision=advise_low_latency',
        diagnostics: <String, Object?>{},
      );

      final plan = VGStreamingStartupPlanner.fromPreflight(report);

      expect(plan.shouldProceed, isTrue);
      expect(plan.reason, equals('advise_low_latency'));
      expect(
        plan.recommendedNetworkProfile,
        equals(VGStreamingNetworkProfile.lowLatency),
      );
      expect(plan.warnings, isEmpty);

      final options = plan.buildPlaybackOptions(
        uri: Uri.parse('https://example.com/live.m3u8'),
        initialWidth: 1920,
        initialHeight: 1080,
        formatHint: VGStreamingFormatHint.hls,
        autoPlay: false,
        initialPositionMs: 5000,
      );

      expect(options.formatHint, equals(VGStreamingFormatHint.hls));
      expect(
        options.networkProfile,
        equals(VGStreamingNetworkProfile.lowLatency),
      );
      expect(options.autoPlay, isFalse);
      expect(options.initialPositionMs, equals(5000));
    });

    test('passing report with STABLE maps correctly', () {
      const report = VGStreamingPreflightReport(
        pass: true,
        phase: 'Phase4C5G',
        advisoryDecision: 'advise_stable',
        requestedNetworkProfile: 'STABLE',
        recommendedNetworkProfile: 'STABLE',
        recommendedNetworkPolicy: <String, Object?>{'profile': 'STABLE'},
        totalReports: 2,
        passedReports: 2,
        failedReports: 0,
        warnings: <String>[],
        deviceWarnings: <String>[],
        llHlsAvailable: false,
        advisoryOnly: true,
        playbackMutation: false,
        serverLadderPolicy: '',
        iosMirrorNote: '',
        raw: 'status=OK;decision=advise_stable',
        diagnostics: <String, Object?>{},
      );

      final plan = VGStreamingStartupPlan.fromPreflight(report);

      expect(plan.shouldProceed, isTrue);
      expect(plan.reason, equals('advise_stable'));
      expect(
        plan.recommendedNetworkProfile,
        equals(VGStreamingNetworkProfile.stable),
      );

      final options = plan.buildPlaybackOptions(
        uri: Uri.parse('https://example.com/vod.mpd'),
        initialWidth: 3840,
        initialHeight: 2160,
        formatHint: VGStreamingFormatHint.dash,
        httpHeaders: {'Authorization': 'Bearer token_abc'},
        cacheOptions: const VGPlaybackCacheOptions(
          cacheEnabled: true,
          cacheMaxBytes: 50 * 1024 * 1024,
          cacheDirectoryName: 'startup_plan_cache',
          minimumFreeBytesAfterPrewarm: 16 * 1024 * 1024,
        ),
      );

      expect(options.formatHint, equals(VGStreamingFormatHint.dash));
      expect(options.networkProfile, equals(VGStreamingNetworkProfile.stable));
      expect(
        options.httpHeaders,
        equals({'Authorization': 'Bearer token_abc'}),
      );
      expect(options.cacheOptions?.cacheEnabled, isTrue);
      expect(options.cacheOptions?.cacheMaxBytes, equals(50 * 1024 * 1024));
    });

    test(
      'failed preflight report produces shouldProceed=false, constrained fallback, and buildPlaybackOptions throws',
      () {
        const report = VGStreamingPreflightReport(
          pass: false,
          phase: 'Phase4C5G',
          advisoryDecision: 'blocked_codec_unsupported',
          requestedNetworkProfile: 'STABLE',
          recommendedNetworkProfile: 'STABLE',
          recommendedNetworkPolicy: <String, Object?>{},
          totalReports: 1,
          passedReports: 0,
          failedReports: 1,
          warnings: <String>['no_compatible_codecs'],
          deviceWarnings: <String>['hevc_unavailable'],
          llHlsAvailable: false,
          advisoryOnly: true,
          playbackMutation: false,
          serverLadderPolicy: '',
          iosMirrorNote: '',
          raw: 'status=ERROR;decision=blocked_codec_unsupported',
          diagnostics: <String, Object?>{},
        );

        final plan = VGStreamingStartupPlan.fromPreflight(report);

        expect(plan.shouldProceed, isFalse);
        expect(plan.reason, equals('blocked_codec_unsupported'));
        expect(
          plan.recommendedNetworkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(
          plan.warnings,
          containsAll([
            'no_compatible_codecs',
            'hevc_unavailable',
            'preflight_failed',
          ]),
        );

        expect(
          () => plan.buildPlaybackOptions(
            uri: Uri.parse('https://example.com/failed.m3u8'),
            initialWidth: 1280,
            initialHeight: 720,
          ),
          throwsStateError,
        );
      },
    );

    test(
      'unsupported report from VGStreamingPreflightReport.unsupported() produces shouldProceed=false',
      () {
        final report = VGStreamingPreflightReport.unsupported();
        final plan = VGStreamingStartupPlan.fromPreflight(report);

        expect(plan.shouldProceed, isFalse);
        expect(plan.reason, equals('unsupported'));
        expect(
          plan.recommendedNetworkProfile,
          equals(VGStreamingNetworkProfile.constrained),
        );
        expect(
          plan.warnings,
          containsAll(['unsupported_platform', 'unsupported']),
        );

        expect(
          () => plan.buildPlaybackOptions(
            uri: Uri.parse('https://example.com/stream.m3u8'),
            initialWidth: 640,
            initialHeight: 480,
          ),
          throwsStateError,
        );
      },
    );

    test('advisoryOnly violation produces shouldProceed=false', () {
      const report = VGStreamingPreflightReport(
        pass: true,
        phase: 'Phase4C5G',
        advisoryDecision: 'advise_stable',
        requestedNetworkProfile: 'STABLE',
        recommendedNetworkProfile: 'STABLE',
        recommendedNetworkPolicy: <String, Object?>{},
        totalReports: 1,
        passedReports: 1,
        failedReports: 0,
        warnings: <String>[],
        deviceWarnings: <String>[],
        llHlsAvailable: false,
        advisoryOnly: false, // Violation
        playbackMutation: false,
        serverLadderPolicy: '',
        iosMirrorNote: '',
        raw: '',
        diagnostics: <String, Object?>{},
      );

      final plan = VGStreamingStartupPlan.fromPreflight(report);

      expect(plan.shouldProceed, isFalse);
      expect(plan.reason, equals('advisory_only_violation'));
      expect(
        plan.recommendedNetworkProfile,
        equals(VGStreamingNetworkProfile.constrained),
      );
      expect(plan.warnings, contains('preflight_failed'));
      expect(
        () => plan.buildPlaybackOptions(
          uri: Uri.parse('https://example.com/stream.m3u8'),
          initialWidth: 640,
          initialHeight: 480,
        ),
        throwsStateError,
      );
    });

    test('playbackMutation violation produces shouldProceed=false', () {
      const report = VGStreamingPreflightReport(
        pass: true,
        phase: 'Phase4C5G',
        advisoryDecision: 'advise_stable',
        requestedNetworkProfile: 'STABLE',
        recommendedNetworkProfile: 'STABLE',
        recommendedNetworkPolicy: <String, Object?>{},
        totalReports: 1,
        passedReports: 1,
        failedReports: 0,
        warnings: <String>[],
        deviceWarnings: <String>[],
        llHlsAvailable: false,
        advisoryOnly: true,
        playbackMutation: true, // Violation
        serverLadderPolicy: '',
        iosMirrorNote: '',
        raw: '',
        diagnostics: <String, Object?>{},
      );

      final plan = VGStreamingStartupPlan.fromPreflight(report);

      expect(plan.shouldProceed, isFalse);
      expect(plan.reason, equals('playback_mutation_detected'));
      expect(
        plan.recommendedNetworkProfile,
        equals(VGStreamingNetworkProfile.constrained),
      );
      expect(plan.warnings, contains('preflight_failed'));
      expect(
        () => plan.buildPlaybackOptions(
          uri: Uri.parse('https://example.com/stream.m3u8'),
          initialWidth: 640,
          initialHeight: 480,
        ),
        throwsStateError,
      );
    });

    test(
      'generated playback options preserve all caller arguments accurately',
      () {
        const report = VGStreamingPreflightReport(
          pass: true,
          phase: 'Phase4C5G',
          advisoryDecision: 'advise_stable',
          requestedNetworkProfile: 'STABLE',
          recommendedNetworkProfile: 'STABLE',
          recommendedNetworkPolicy: <String, Object?>{},
          totalReports: 1,
          passedReports: 1,
          failedReports: 0,
          warnings: <String>[],
          deviceWarnings: <String>[],
          llHlsAvailable: true,
          advisoryOnly: true,
          playbackMutation: false,
          serverLadderPolicy: '',
          iosMirrorNote: '',
          raw: '',
          diagnostics: <String, Object?>{},
        );

        final plan = VGStreamingStartupPlan.fromPreflight(report);
        final uri = Uri.parse('https://custom.stream.mux.dev/test.m3u8');
        const headers = {'X-Test-Header': 'Val123', 'Cookie': 'sess=abc'};
        const cacheOpts = VGPlaybackCacheOptions(
          cacheEnabled: true,
          cacheMaxBytes: 120 * 1024 * 1024,
          cacheDirectoryName: 'custom_cache_dir',
          minimumFreeBytesAfterPrewarm: 64 * 1024 * 1024,
        );

        final options = plan.buildPlaybackOptions(
          uri: uri,
          initialWidth: 1080,
          initialHeight: 1920,
          httpHeaders: headers,
          formatHint: VGStreamingFormatHint.hls,
          autoPlay: false,
          initialPositionMs: 12500,
          cacheOptions: cacheOpts,
        );

        expect(options.uri, equals(uri));
        expect(options.initialWidth, equals(1080));
        expect(options.initialHeight, equals(1920));
        expect(options.httpHeaders, equals(headers));
        expect(options.formatHint, equals(VGStreamingFormatHint.hls));
        expect(
          options.networkProfile,
          equals(VGStreamingNetworkProfile.stable),
        );
        expect(options.autoPlay, isFalse);
        expect(options.initialPositionMs, equals(12500));
        expect(options.cacheOptions, equals(cacheOpts));

        final args = options.toArgs();
        expect(args['uri'], equals('https://custom.stream.mux.dev/test.m3u8'));
        expect(args['initialWidth'], equals(1080));
        expect(args['initialHeight'], equals(1920));
        expect(args['formatHint'], equals('HLS'));
        expect(args['networkProfile'], equals('STABLE'));
        expect(args['autoPlay'], isFalse);
        expect(args['startPositionMs'], equals(12500));
        expect(args['cacheEnabled'], isTrue);
      },
    );
  });
}
