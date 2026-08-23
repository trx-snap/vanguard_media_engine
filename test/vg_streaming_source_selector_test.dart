// Copyright (c) Connects — Vanguard Phase 4C7K.
// Public streaming source selector unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingSourceSelector', () {
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

    final validPlan = VGStreamingStartupPlan.fromPreflight(validReport);

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

    final blockedPlan = VGStreamingStartupPlan.fromPreflight(blockedReport);

    test('startup plan blocked returns unselected result with warnings', () {
      final request = VGStreamingSourceSelectionRequest(
        sourceSet: sourceSet,
        startupPlan: blockedPlan,
        preference: VGStreamingSourceSelectionPreference.preserveOrder,
        requirePlanToProceed: true,
      );

      final selection = VGStreamingSourceSelector.select(request);

      expect(selection.selected, isFalse);
      expect(selection.selectedKey, isNull);
      expect(selection.source, isNull);
      expect(selection.playbackOptions, isNull);
      expect(selection.decision, equals('startup_plan_blocked'));
      expect(selection.warnings, contains('startup_plan_blocked'));
      expect(selection.warnings, contains('network_unreachable'));
      expect(selection.consideredKeys, isEmpty);
      expect(selection.diagnostics['requirePlanToProceed'], isTrue);
    });

    test(
      'requirePlanToProceed false with blocked plan fails at option derivation',
      () {
        final request = VGStreamingSourceSelectionRequest(
          sourceSet: sourceSet,
          startupPlan: blockedPlan,
          preference: VGStreamingSourceSelectionPreference.preserveOrder,
          requirePlanToProceed: false,
        );

        final selection = VGStreamingSourceSelector.select(request);

        expect(selection.selected, isFalse);
        expect(selection.selectedKey, equals('hls_main'));
        expect(selection.source, equals(hlsSource));
        expect(selection.playbackOptions, isNull);
        expect(selection.decision, equals('playback_options_blocked'));
        expect(selection.warnings, contains('playback_options_blocked'));
        expect(
          selection.consideredKeys,
          equals(['hls_main', 'dash_main', 'll_hls_main']),
        );
      },
    );

    test('preserveOrder selects first candidate in source set', () {
      final request = VGStreamingSourceSelectionRequest(
        sourceSet: sourceSet,
        startupPlan: validPlan,
        preference: VGStreamingSourceSelectionPreference.preserveOrder,
      );

      final selection = VGStreamingSourceSelector.select(request);

      expect(selection.selected, isTrue);
      expect(selection.selectedKey, equals('hls_main'));
      expect(selection.source, equals(hlsSource));
      expect(selection.decision, equals('source_selected'));
      expect(
        selection.consideredKeys,
        equals(['hls_main', 'dash_main', 'll_hls_main']),
      );
      expect(selection.warnings, isEmpty);
    });

    test('preferredKeys chooses exact source and respects key order', () {
      final request1 = VGStreamingSourceSelectionRequest(
        sourceSet: sourceSet,
        startupPlan: validPlan,
        preference: VGStreamingSourceSelectionPreference.preserveOrder,
        preferredKeys: ['dash_main', 'hls_main'],
      );

      final selection1 = VGStreamingSourceSelector.select(request1);
      expect(selection1.selected, isTrue);
      expect(selection1.selectedKey, equals('dash_main'));
      expect(selection1.consideredKeys, equals(['dash_main', 'hls_main']));

      final request2 = VGStreamingSourceSelectionRequest(
        sourceSet: sourceSet,
        startupPlan: validPlan,
        preference: VGStreamingSourceSelectionPreference.preserveOrder,
        preferredKeys: ['ll_hls_main'],
      );

      final selection2 = VGStreamingSourceSelector.select(request2);
      expect(selection2.selected, isTrue);
      expect(selection2.selectedKey, equals('ll_hls_main'));
      expect(selection2.consideredKeys, equals(['ll_hls_main']));
    });

    test('unknown preferred keys emit warnings and fall back gracefully', () {
      // Partial match: some unknown, some known.
      final partialRequest = VGStreamingSourceSelectionRequest(
        sourceSet: sourceSet,
        startupPlan: validPlan,
        preference: VGStreamingSourceSelectionPreference.preserveOrder,
        preferredKeys: ['missing_key_1', 'dash_main', 'missing_key_2'],
      );

      final partialSelection = VGStreamingSourceSelector.select(partialRequest);
      expect(partialSelection.selected, isTrue);
      expect(partialSelection.selectedKey, equals('dash_main'));
      expect(partialSelection.consideredKeys, equals(['dash_main']));
      expect(
        partialSelection.warnings,
        contains('unknown_preferred_key:missing_key_1'),
      );
      expect(
        partialSelection.warnings,
        contains('unknown_preferred_key:missing_key_2'),
      );

      // Total mismatch: all unknown -> falls back to all sources in source set.
      final fallbackRequest = VGStreamingSourceSelectionRequest(
        sourceSet: sourceSet,
        startupPlan: validPlan,
        preference: VGStreamingSourceSelectionPreference.preferDash,
        preferredKeys: ['unknown_a', 'unknown_b'],
      );

      final fallbackSelection = VGStreamingSourceSelector.select(
        fallbackRequest,
      );
      expect(fallbackSelection.selected, isTrue);
      expect(fallbackSelection.selectedKey, equals('dash_main'));
      expect(
        fallbackSelection.consideredKeys,
        equals(['hls_main', 'dash_main', 'll_hls_main']),
      );
      expect(
        fallbackSelection.warnings,
        contains('unknown_preferred_key:unknown_a'),
      );
      expect(
        fallbackSelection.warnings,
        contains('unknown_preferred_key:unknown_b'),
      );
    });

    test(
      'preferHls selects HLS candidate or falls back to first candidate',
      () {
        final request = VGStreamingSourceSelectionRequest(
          sourceSet: VGStreamingSourceSet(sources: [dashSource, hlsSource]),
          startupPlan: validPlan,
          preference: VGStreamingSourceSelectionPreference.preferHls,
        );

        final selection = VGStreamingSourceSelector.select(request);
        expect(selection.selected, isTrue);
        expect(selection.selectedKey, equals('hls_main'));

        // Fallback when no HLS exists:
        final noHlsSet = VGStreamingSourceSet(sources: [dashSource]);
        final noHlsRequest = VGStreamingSourceSelectionRequest(
          sourceSet: noHlsSet,
          startupPlan: validPlan,
          preference: VGStreamingSourceSelectionPreference.preferHls,
        );

        final noHlsSelection = VGStreamingSourceSelector.select(noHlsRequest);
        expect(noHlsSelection.selected, isTrue);
        expect(noHlsSelection.selectedKey, equals('dash_main'));
      },
    );

    test(
      'preferDash selects DASH candidate or falls back to first candidate',
      () {
        final request = VGStreamingSourceSelectionRequest(
          sourceSet: sourceSet,
          startupPlan: validPlan,
          preference: VGStreamingSourceSelectionPreference.preferDash,
        );

        final selection = VGStreamingSourceSelector.select(request);
        expect(selection.selected, isTrue);
        expect(selection.selectedKey, equals('dash_main'));

        // Fallback when no DASH exists:
        final noDashSet = VGStreamingSourceSet(
          sources: [hlsSource, llHlsSource],
        );
        final noDashRequest = VGStreamingSourceSelectionRequest(
          sourceSet: noDashSet,
          startupPlan: validPlan,
          preference: VGStreamingSourceSelectionPreference.preferDash,
        );

        final noDashSelection = VGStreamingSourceSelector.select(noDashRequest);
        expect(noDashSelection.selected, isTrue);
        expect(noDashSelection.selectedKey, equals('hls_main'));
      },
    );

    test(
      'preferLowLatency selects LL candidate or falls back to first candidate',
      () {
        final request = VGStreamingSourceSelectionRequest(
          sourceSet: sourceSet,
          startupPlan: validPlan,
          preference: VGStreamingSourceSelectionPreference.preferLowLatency,
        );

        final selection = VGStreamingSourceSelector.select(request);
        expect(selection.selected, isTrue);
        expect(selection.selectedKey, equals('ll_hls_main'));

        // Fallback when no LL candidate exists:
        final noLlSet = VGStreamingSourceSet(sources: [dashSource, hlsSource]);
        final noLlRequest = VGStreamingSourceSelectionRequest(
          sourceSet: noLlSet,
          startupPlan: validPlan,
          preference: VGStreamingSourceSelectionPreference.preferLowLatency,
        );

        final noLlSelection = VGStreamingSourceSelector.select(noLlRequest);
        expect(noLlSelection.selected, isTrue);
        expect(noLlSelection.selectedKey, equals('dash_main'));
      },
    );

    test(
      'preferConstrainedReliability selects non-LL candidate or falls back',
      () {
        final request = VGStreamingSourceSelectionRequest(
          sourceSet: VGStreamingSourceSet(sources: [llHlsSource, hlsSource]),
          startupPlan: validPlan,
          preference:
              VGStreamingSourceSelectionPreference.preferConstrainedReliability,
        );

        final selection = VGStreamingSourceSelector.select(request);
        expect(selection.selected, isTrue);
        expect(selection.selectedKey, equals('hls_main'));

        // Fallback when all candidates require LL tags:
        final onlyLlSet = VGStreamingSourceSet(sources: [llHlsSource]);
        final onlyLlRequest = VGStreamingSourceSelectionRequest(
          sourceSet: onlyLlSet,
          startupPlan: validPlan,
          preference:
              VGStreamingSourceSelectionPreference.preferConstrainedReliability,
        );

        final onlyLlSelection = VGStreamingSourceSelector.select(onlyLlRequest);
        expect(onlyLlSelection.selected, isTrue);
        expect(onlyLlSelection.selectedKey, equals('ll_hls_main'));
      },
    );

    test(
      'playbackOptions preserve URI, format, dimensions, headers, and cache',
      () {
        final request = VGStreamingSourceSelectionRequest(
          sourceSet: sourceSet,
          startupPlan: validPlan,
          preference: VGStreamingSourceSelectionPreference.preferHls,
        );

        final selection = VGStreamingSourceSelector.select(request);
        expect(selection.selected, isTrue);
        final options = selection.playbackOptions;
        expect(options, isNotNull);
        expect(
          options!.uri,
          equals(Uri.parse('https://example.com/main.m3u8')),
        );
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
      },
    );

    test('toString formats objects cleanly', () {
      final request = VGStreamingSourceSelectionRequest(
        sourceSet: sourceSet,
        startupPlan: validPlan,
        preferredKeys: ['hls_main'],
      );
      expect(request.toString(), contains('preferredKeys=[hls_main]'));

      final selection = VGStreamingSourceSelector.select(request);
      expect(selection.toString(), contains('selected=true'));
      expect(selection.toString(), contains('selectedKey=hls_main'));
    });
  });
}
