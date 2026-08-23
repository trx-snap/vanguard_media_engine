// Copyright (c) Connects — Vanguard Phase 4C7I.
// Public streaming source descriptor & source set unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingSourceDescriptor', () {
    test('constructor asserts on invalid parameters', () {
      expect(
        () => VGStreamingSourceDescriptor(
          key: '',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          initialWidth: 1920,
          initialHeight: 1080,
        ),
        throwsAssertionError,
      );

      expect(
        () => VGStreamingSourceDescriptor(
          key: 'valid_key',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          initialWidth: 0,
          initialHeight: 1080,
        ),
        throwsAssertionError,
      );

      expect(
        () => VGStreamingSourceDescriptor(
          key: 'valid_key',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          initialWidth: -100,
          initialHeight: 1080,
        ),
        throwsAssertionError,
      );

      expect(
        () => VGStreamingSourceDescriptor(
          key: 'valid_key',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          initialWidth: 1920,
          initialHeight: 0,
        ),
        throwsAssertionError,
      );

      expect(
        () => VGStreamingSourceDescriptor(
          key: 'valid_key',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          initialWidth: 1920,
          initialHeight: -50,
        ),
        throwsAssertionError,
      );

      expect(
        () => VGStreamingSourceDescriptor(
          key: 'valid_key',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          initialWidth: 1920,
          initialHeight: 1080,
          initialPositionMs: -1,
        ),
        throwsAssertionError,
      );
    });

    test('toManifestSpec preserves URI, key, format hint, flags, headers', () {
      final uri = Uri.parse('https://live.example.com/master.m3u8');
      const headers = {
        'Authorization': 'Bearer token_123',
        'X-Client-Version': '2.0',
      };

      final descriptor = VGStreamingSourceDescriptor(
        key: 'live_primary',
        uri: uri,
        initialWidth: 1080,
        initialHeight: 1920,
        formatHint: VGStreamingFormatHint.hls,
        httpHeaders: headers,
        requireAdaptiveLadder: false,
        requireAvcFallback: false,
        requireLlHlsTags: true,
        allowMediaPlaylist: true,
        autoPlay: false,
        initialPositionMs: 3000,
      );

      final spec = descriptor.toManifestSpec();

      expect(spec.key, equals('live_primary'));
      expect(spec.uri, equals(uri));
      expect(spec.formatHint, equals(VGStreamingFormatHint.hls));
      expect(spec.requireAdaptiveLadder, isFalse);
      expect(spec.requireAvcFallback, isFalse);
      expect(spec.requireLlHlsTags, isTrue);
      expect(spec.allowMediaPlaylist, isTrue);
      expect(spec.httpHeaders, equals(headers));

      final args = spec.toArgs();
      expect(args['key'], equals('live_primary'));
      expect(args['uri'], equals('https://live.example.com/master.m3u8'));
      expect(args['formatHint'], equals('HLS'));
      expect(args['requireAdaptiveLadder'], isFalse);
      expect(args['requireAvcFallback'], isFalse);
      expect(args['requireLlHlsTags'], isTrue);
      expect(args['allowMediaPlaylist'], isTrue);
      expect(args['httpHeaders'], equals(headers));
    });

    test(
      'toPlaybackOptions preserves all parameters and uses plan recommended network profile',
      () {
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

        final plan = VGStreamingStartupPlan.fromPreflight(report);
        final uri = Uri.parse('https://vod.example.com/manifest.mpd');
        const headers = {'X-Custom-Auth': 'secret'};
        const cacheOpts = VGPlaybackCacheOptions(
          cacheEnabled: true,
          cacheMaxBytes: 100 * 1024 * 1024,
          cacheDirectoryName: 'source_test_cache',
          minimumFreeBytesAfterPrewarm: 32 * 1024 * 1024,
        );

        final descriptor = VGStreamingSourceDescriptor(
          key: 'vod_dash',
          uri: uri,
          initialWidth: 3840,
          initialHeight: 2160,
          formatHint: VGStreamingFormatHint.dash,
          httpHeaders: headers,
          cacheOptions: cacheOpts,
          autoPlay: false,
          initialPositionMs: 45000,
        );

        final options = descriptor.toPlaybackOptions(plan);

        expect(options.uri, equals(uri));
        expect(options.initialWidth, equals(3840));
        expect(options.initialHeight, equals(2160));
        expect(options.formatHint, equals(VGStreamingFormatHint.dash));
        expect(
          options.networkProfile,
          equals(VGStreamingNetworkProfile.lowLatency),
        );
        expect(options.httpHeaders, equals(headers));
        expect(options.cacheOptions, equals(cacheOpts));
        expect(options.autoPlay, isFalse);
        expect(options.initialPositionMs, equals(45000));

        final args = options.toArgs();
        expect(args['uri'], equals('https://vod.example.com/manifest.mpd'));
        expect(args['initialWidth'], equals(3840));
        expect(args['initialHeight'], equals(2160));
        expect(args['formatHint'], equals('DASH'));
        expect(args['networkProfile'], equals('LOW_LATENCY'));
        expect(args['autoPlay'], isFalse);
        expect(args['startPositionMs'], equals(45000));
        expect(args['cacheEnabled'], isTrue);
      },
    );

    test(
      'failed startup plan causes toPlaybackOptions to throw via plan gating',
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
          deviceWarnings: <String>[],
          llHlsAvailable: false,
          advisoryOnly: true,
          playbackMutation: false,
          serverLadderPolicy: '',
          iosMirrorNote: '',
          raw: '',
          diagnostics: <String, Object?>{},
        );

        final plan = VGStreamingStartupPlan.fromPreflight(report);
        final descriptor = VGStreamingSourceDescriptor(
          key: 'failed_source',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          initialWidth: 1280,
          initialHeight: 720,
        );

        expect(() => descriptor.toPlaybackOptions(plan), throwsStateError);
      },
    );

    test('copyWith updates specified fields and preserves existing fields', () {
      final base = VGStreamingSourceDescriptor(
        key: 'base_key',
        uri: Uri.parse('https://example.com/base.m3u8'),
        initialWidth: 1280,
        initialHeight: 720,
        formatHint: VGStreamingFormatHint.hls,
        httpHeaders: {'Header1': 'Val1'},
        requireAdaptiveLadder: true,
        requireAvcFallback: true,
        requireLlHlsTags: false,
        allowMediaPlaylist: false,
        cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
        autoPlay: true,
        initialPositionMs: 1000,
      );

      final updated = base.copyWith(
        key: 'new_key',
        initialWidth: 1920,
        initialHeight: 1080,
        autoPlay: false,
        initialPositionMs: 5000,
      );

      expect(updated.key, equals('new_key'));
      expect(updated.uri, equals(base.uri));
      expect(updated.initialWidth, equals(1920));
      expect(updated.initialHeight, equals(1080));
      expect(updated.formatHint, equals(VGStreamingFormatHint.hls));
      expect(updated.httpHeaders, equals({'Header1': 'Val1'}));
      expect(updated.requireAdaptiveLadder, isTrue);
      expect(updated.requireAvcFallback, isTrue);
      expect(updated.requireLlHlsTags, isFalse);
      expect(updated.allowMediaPlaylist, isFalse);
      expect(updated.cacheOptions?.cacheEnabled, isTrue);
      expect(updated.autoPlay, isFalse);
      expect(updated.initialPositionMs, equals(5000));
      expect(updated.toString(), contains('new_key'));
    });
  });

  group('VGStreamingSourceSet', () {
    final source1 = VGStreamingSourceDescriptor(
      key: 'stream_hls',
      uri: Uri.parse('https://example.com/stream.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
    );

    final source2 = VGStreamingSourceDescriptor(
      key: 'stream_dash',
      uri: Uri.parse('https://example.com/stream.mpd'),
      initialWidth: 1280,
      initialHeight: 720,
      formatHint: VGStreamingFormatHint.dash,
      requireLlHlsTags: false,
    );

    test('rejects empty source list', () {
      expect(
        () => VGStreamingSourceSet(sources: <VGStreamingSourceDescriptor>[]),
        throwsAssertionError,
      );
    });

    test('rejects duplicate keys', () {
      final duplicateSource = VGStreamingSourceDescriptor(
        key: 'stream_hls',
        uri: Uri.parse('https://example.com/stream2.m3u8'),
        initialWidth: 1280,
        initialHeight: 720,
      );

      expect(
        () => VGStreamingSourceSet(sources: [source1, duplicateSource]),
        throwsAssertionError,
      );
    });

    test('builds preflight request with all source manifest specs', () {
      final sourceSet = VGStreamingSourceSet(sources: [source1, source2]);

      final request = sourceSet.toPreflightRequest(
        requestedNetworkProfile: VGStreamingNetworkProfile.stable,
        preferLowLatency: true,
        allowLowLatencyOnConstrained: true,
      );

      expect(request.manifests.length, equals(2));
      expect(request.manifests[0].key, equals('stream_hls'));
      expect(
        request.manifests[0].uri,
        equals(Uri.parse('https://example.com/stream.m3u8')),
      );
      expect(
        request.manifests[0].formatHint,
        equals(VGStreamingFormatHint.hls),
      );
      expect(request.manifests[1].key, equals('stream_dash'));
      expect(
        request.manifests[1].uri,
        equals(Uri.parse('https://example.com/stream.mpd')),
      );
      expect(
        request.manifests[1].formatHint,
        equals(VGStreamingFormatHint.dash),
      );
      expect(
        request.requestedNetworkProfile,
        equals(VGStreamingNetworkProfile.stable),
      );
      expect(request.preferLowLatency, isTrue);
      expect(request.allowLowLatencyOnConstrained, isTrue);

      final args = request.toArgs();
      expect((args['manifests'] as List).length, equals(2));
      expect(args['requestedNetworkProfile'], equals('STABLE'));
      expect(args['preferLowLatency'], isTrue);
      expect(args['allowLowLatencyOnConstrained'], isTrue);
    });

    test(
      'source lookup by key works and missing key behavior is deterministic',
      () {
        final sourceSet = VGStreamingSourceSet(sources: [source1, source2]);

        expect(sourceSet.trySourceForKey('stream_hls'), equals(source1));
        expect(sourceSet.trySourceForKey('stream_dash'), equals(source2));
        expect(sourceSet.trySourceForKey('missing_key'), isNull);

        expect(sourceSet.sourceForKey('stream_hls'), equals(source1));
        expect(sourceSet.sourceForKey('stream_dash'), equals(source2));
        expect(
          () => sourceSet.sourceForKey('non_existent'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('No source found for key "non_existent" in source set.'),
            ),
          ),
        );

        expect(sourceSet.toString(), contains('stream_hls'));
      },
    );
  });
}
