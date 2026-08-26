// Copyright (c) Connects — Vanguard Phase 4C7BE.
// Public streaming offline asset eligibility planner unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingOfflineAssetEligibilityPlanner', () {
    final hlsSource = VGStreamingSourceDescriptor(
      key: 'hls_main',
      uri: Uri.parse('https://example.com/main.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
      httpHeaders: const {'Authorization': 'Bearer token'},
    );

    final hlsSecondary = VGStreamingSourceDescriptor(
      key: 'hls_secondary',
      uri: Uri.parse('https://example.com/secondary.m3u8'),
      initialWidth: 1280,
      initialHeight: 720,
      formatHint: VGStreamingFormatHint.hls,
    );

    final llHlsSource = VGStreamingSourceDescriptor(
      key: 'll_hls_main',
      uri: Uri.parse('https://example.com/ll_stream.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
      requireLlHlsTags: true,
    );

    final dashSource = VGStreamingSourceDescriptor(
      key: 'dash_main',
      uri: Uri.parse('https://example.com/main.mpd'),
      initialWidth: 1280,
      initialHeight: 720,
      formatHint: VGStreamingFormatHint.dash,
    );

    final unknownFormatSource = VGStreamingSourceDescriptor(
      key: 'custom_format',
      uri: Uri.parse('https://example.com/stream.bin'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.auto,
    );

    final invalidSchemeSource = VGStreamingSourceDescriptor(
      key: 'file_scheme',
      uri: Uri.parse('file:///local/stream.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
    );

    test(
      'HLS source is eligible and candidate toArgs preserves URI, headers, format, sourceKey',
      () {
        final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
          VGStreamingOfflineAssetEligibilityRequest(
            sourceSet: VGStreamingSourceSet(sources: [hlsSource]),
          ),
        );

        expect(plan.hasCandidates, isTrue);
        expect(plan.hasRejections, isFalse);
        expect(plan.candidates, hasLength(1));

        final candidate = plan.candidates.single;
        expect(candidate.sourceKey, equals('hls_main'));
        expect(candidate.uri, equals(hlsSource.uri));
        expect(candidate.formatHint, equals(VGStreamingFormatHint.hls));
        expect(candidate.requireLlHlsTags, isFalse);

        final args = candidate.toArgs();
        expect(args['sourceKey'], equals('hls_main'));
        expect(args['uri'], equals(hlsSource.uri.toString()));
        expect(args['httpHeaders'], equals({'Authorization': 'Bearer token'}));
        expect(args['formatHint'], equals('HLS'));
        expect(args['requireLlHlsTags'], isFalse);

        expect(plan.diagnostics['candidateCount'], equals(1));
        expect(plan.diagnostics['rejectedCount'], equals(0));
        expect(plan.diagnostics['advisoryOnly'], isTrue);
        expect(plan.diagnostics['playbackMutation'], isFalse);
      },
    );

    test('sourceKeys filters and preserves order', () {
      final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
        VGStreamingOfflineAssetEligibilityRequest(
          sourceSet: VGStreamingSourceSet(sources: [hlsSource, hlsSecondary]),
          sourceKeys: const ['hls_secondary', 'hls_main'],
        ),
      );

      expect(plan.candidates, hasLength(2));
      expect(plan.candidates[0].sourceKey, equals('hls_secondary'));
      expect(plan.candidates[1].sourceKey, equals('hls_main'));
      expect(plan.diagnostics['evaluatedCount'], equals(2));
    });

    test(
      'unknown and duplicate keys produce expected warning/unknown list/deduped evaluation',
      () {
        final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
          VGStreamingOfflineAssetEligibilityRequest(
            sourceSet: VGStreamingSourceSet(sources: [hlsSource]),
            sourceKeys: const ['hls_main', 'nonexistent_key', 'hls_main'],
          ),
        );

        expect(plan.candidates, hasLength(1));
        expect(plan.unknownKeys, equals(['nonexistent_key']));
        expect(plan.warnings, contains('unknown_source_key:nonexistent_key'));
        expect(plan.warnings, contains('duplicate_source_key:hls_main'));
        expect(plan.diagnostics['evaluatedCount'], equals(1));
        expect(plan.diagnostics['unknownKeyCount'], equals(1));
      },
    );

    test(
      'LL-HLS rejected by default with lowLatencyConstrained and warning',
      () {
        final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
          VGStreamingOfflineAssetEligibilityRequest(
            sourceSet: VGStreamingSourceSet(sources: [llHlsSource]),
          ),
        );

        expect(plan.hasCandidates, isFalse);
        expect(plan.rejectedSources, hasLength(1));

        final rejection = plan.rejectedSources.single;
        expect(rejection.sourceKey, equals('ll_hls_main'));
        expect(
          rejection.state,
          equals(VGStreamingOfflineAssetEligibilityState.lowLatencyConstrained),
        );
        expect(rejection.reason, equals('low_latency_offline_constrained'));
        expect(
          plan.warnings,
          contains(
            'offline_rejected:ll_hls_main:low_latency_offline_constrained',
          ),
        );

        final json = rejection.toJson();
        expect(json['sourceKey'], equals('ll_hls_main'));
        expect(json['state'], equals('lowLatencyConstrained'));
        expect(json['reason'], equals('low_latency_offline_constrained'));
      },
    );

    test(
      'LL-HLS allowed when allowLowLatency true and client supportsLowLatencyHls true',
      () {
        final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
          VGStreamingOfflineAssetEligibilityRequest(
            sourceSet: VGStreamingSourceSet(sources: [llHlsSource]),
            allowLowLatency: true,
            clientCapabilities:
                const VGStreamingSourceClientCapabilities.appleAvPlayer(),
          ),
        );

        expect(plan.hasCandidates, isTrue);
        expect(plan.hasRejections, isFalse);
        expect(plan.candidates.single.requireLlHlsTags, isTrue);
      },
    );

    test('DASH rejected by default with dash_offline_deferred', () {
      final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
        VGStreamingOfflineAssetEligibilityRequest(
          sourceSet: VGStreamingSourceSet(sources: [dashSource]),
        ),
      );

      expect(plan.hasCandidates, isFalse);
      final rejection = plan.rejectedSources.single;
      expect(
        rejection.state,
        equals(VGStreamingOfflineAssetEligibilityState.unsupportedFormat),
      );
      expect(rejection.reason, equals('dash_offline_deferred'));
    });

    test(
      'DASH is eligible only when allowDash true and client supportsDash true '
      '(non-Apple advisory only — never applies to Apple platforms)',
      () {
        final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
          VGStreamingOfflineAssetEligibilityRequest(
            sourceSet: VGStreamingSourceSet(sources: [dashSource]),
            allowDash: true,
            clientCapabilities:
                const VGStreamingSourceClientCapabilities.androidMedia3(),
          ),
        );

        expect(plan.hasCandidates, isTrue);
        expect(
          plan.candidates.single.formatHint,
          equals(VGStreamingFormatHint.dash),
        );
        expect(plan.diagnostics['allowDash'], isTrue);
      },
    );

    test(
      'Apple AVPlayer capabilities reject DASH even if allowDash true with client_unsupported_dash',
      () {
        final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
          VGStreamingOfflineAssetEligibilityRequest(
            sourceSet: VGStreamingSourceSet(sources: [dashSource]),
            allowDash: true,
            clientCapabilities:
                const VGStreamingSourceClientCapabilities.appleAvPlayer(),
          ),
        );

        expect(plan.hasCandidates, isFalse);
        final rejection = plan.rejectedSources.single;
        expect(
          rejection.state,
          equals(VGStreamingOfflineAssetEligibilityState.clientUnsupported),
        );
        expect(rejection.reason, equals('client_unsupported_dash'));
      },
    );

    test('client with supportsHls false rejects HLS', () {
      final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
        VGStreamingOfflineAssetEligibilityRequest(
          sourceSet: VGStreamingSourceSet(sources: [hlsSource]),
          clientCapabilities: const VGStreamingSourceClientCapabilities(
            clientType: 'no_hls_client',
            supportsHls: false,
          ),
        ),
      );

      expect(plan.hasCandidates, isFalse);
      final rejection = plan.rejectedSources.single;
      expect(
        rejection.state,
        equals(VGStreamingOfflineAssetEligibilityState.clientUnsupported),
      );
      expect(rejection.reason, equals('client_unsupported_hls'));
    });

    test('invalid URI scheme rejected invalidSource', () {
      final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
        VGStreamingOfflineAssetEligibilityRequest(
          sourceSet: VGStreamingSourceSet(sources: [invalidSchemeSource]),
        ),
      );

      expect(plan.hasCandidates, isFalse);
      final rejection = plan.rejectedSources.single;
      expect(
        rejection.state,
        equals(VGStreamingOfflineAssetEligibilityState.invalidSource),
      );
      expect(rejection.reason, equals('invalid_offline_uri_scheme'));
    });

    test('unsupported format rejected unsupportedFormat', () {
      final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
        VGStreamingOfflineAssetEligibilityRequest(
          sourceSet: VGStreamingSourceSet(sources: [unknownFormatSource]),
        ),
      );

      expect(plan.hasCandidates, isFalse);
      final rejection = plan.rejectedSources.single;
      expect(
        rejection.state,
        equals(VGStreamingOfflineAssetEligibilityState.unsupportedFormat),
      );
      expect(rejection.reason, equals('unsupported_offline_format'));
    });

    test('plan collections are immutable', () {
      final plan = VGStreamingOfflineAssetEligibilityPlanner.plan(
        VGStreamingOfflineAssetEligibilityRequest(
          sourceSet: VGStreamingSourceSet(sources: [hlsSource, dashSource]),
        ),
      );

      expect(
        () => plan.candidates.add(
          VGStreamingOfflineAssetCandidate(
            sourceKey: 'x',
            uri: Uri.parse('https://example.com/x.m3u8'),
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => plan.rejectedSources.add(
          VGStreamingOfflineAssetRejectedSource(
            sourceKey: 'x',
            state: VGStreamingOfflineAssetEligibilityState.invalidSource,
            reason: 'x',
          ),
        ),
        throwsUnsupportedError,
      );
      expect(() => plan.unknownKeys.add('x'), throwsUnsupportedError);
      expect(() => plan.warnings.add('x'), throwsUnsupportedError);
      expect(() => plan.diagnostics['x'] = 'y', throwsUnsupportedError);
    });

    test(
      'VGStreamingOfflineAssetEligibilityRequest sourceKeys is immutable',
      () {
        final request = VGStreamingOfflineAssetEligibilityRequest(
          sourceSet: VGStreamingSourceSet(sources: [hlsSource]),
          sourceKeys: const ['hls_main'],
        );
        expect(() => request.sourceKeys.add('x'), throwsUnsupportedError);
        expect(request.toString(), contains('allowLowLatency=false'));
      },
    );

    test('VGStreamingOfflineAssetCandidate asserts non-empty sourceKey', () {
      expect(
        () => VGStreamingOfflineAssetCandidate(
          sourceKey: '',
          uri: Uri.parse('https://example.com/x.m3u8'),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test(
      'VGStreamingOfflineAssetRejectedSource asserts non-empty sourceKey and reason',
      () {
        expect(
          () => VGStreamingOfflineAssetRejectedSource(
            sourceKey: '',
            state: VGStreamingOfflineAssetEligibilityState.invalidSource,
            reason: 'x',
          ),
          throwsA(isA<AssertionError>()),
        );
        expect(
          () => VGStreamingOfflineAssetRejectedSource(
            sourceKey: 'x',
            state: VGStreamingOfflineAssetEligibilityState.invalidSource,
            reason: '',
          ),
          throwsA(isA<AssertionError>()),
        );
      },
    );
  });
}
