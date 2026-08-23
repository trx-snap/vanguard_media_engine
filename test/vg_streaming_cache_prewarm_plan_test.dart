// Copyright (c) Connects — Vanguard Phase 4C6K.
// Public streaming cache prewarm request planner unit tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('vanguard_media_engine');
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(channel, null);
  });

  group('VGPlaybackPrewarmRequest', () {
    test('constructor asserts on invalid parameters', () {
      expect(
        () => VGPlaybackPrewarmRequest(
          requestId: '',
          uri: Uri.parse('https://example.com/stream.m3u8'),
        ),
        throwsAssertionError,
      );

      expect(
        () => VGPlaybackPrewarmRequest(
          requestId: 'valid_id',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          maxBytes: 0,
        ),
        throwsAssertionError,
      );

      expect(
        () => VGPlaybackPrewarmRequest(
          requestId: 'valid_id',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          maxBytes: -1,
        ),
        throwsAssertionError,
      );
    });

    test('toArgs serializes all fields matching prewarm args', () {
      final uri = Uri.parse('https://example.com/live/master.m3u8');
      const headers = {'Authorization': 'Bearer test_token'};
      const options = VGPlaybackCacheOptions(
        cacheEnabled: true,
        cacheMaxBytes: 128 * 1024 * 1024,
        cacheDirectoryName: 'prewarm_cache',
        minimumFreeBytesAfterPrewarm: 32 * 1024 * 1024,
      );

      final request = VGPlaybackPrewarmRequest(
        requestId: 'req-001',
        uri: uri,
        httpHeaders: headers,
        maxBytes: 4 * 1024 * 1024,
        options: options,
      );

      final args = request.toArgs();

      expect(args['requestId'], equals('req-001'));
      expect(args['uri'], equals('https://example.com/live/master.m3u8'));
      expect(args['httpHeaders'], equals(headers));
      expect(args['maxBytes'], equals(4 * 1024 * 1024));
      expect(args['cacheEnabled'], isTrue);
      expect(args['cacheMaxBytes'], equals(128 * 1024 * 1024));
      expect(args['cacheDirectoryName'], equals('prewarm_cache'));
      expect(args['minimumFreeBytesAfterPrewarm'], equals(32 * 1024 * 1024));
      expect(request.toString(), contains('req-001'));
    });
  });

  group('VGStreamingCachePrewarmPlan', () {
    test('hasRequests derived getter reflects requests emptiness', () {
      const emptyPlan = VGStreamingCachePrewarmPlan(
        requests: [],
        skippedKeys: ['skipped_1'],
        warnings: ['warning_1'],
      );
      expect(emptyPlan.hasRequests, isFalse);

      final nonEmptyPlan = VGStreamingCachePrewarmPlan(
        requests: [
          VGPlaybackPrewarmRequest(
            requestId: 'req-1',
            uri: Uri.parse('https://example.com/test.m3u8'),
          ),
        ],
      );
      expect(nonEmptyPlan.hasRequests, isTrue);
      expect(nonEmptyPlan.toString(), contains('requests=1'));
    });
  });

  group('VGStreamingCachePrewarmPlanner.requestForSource', () {
    final hlsSource = VGStreamingSourceDescriptor(
      key: 'hls_main',
      uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
      initialWidth: 1080,
      initialHeight: 1920,
      formatHint: VGStreamingFormatHint.hls,
      httpHeaders: const {'X-Header': 'Val'},
      cacheOptions: const VGPlaybackCacheOptions(
        cacheEnabled: true,
        cacheMaxBytes: 64 * 1024 * 1024,
        cacheDirectoryName: 'source_cache',
      ),
    );

    test('preserves URI, headers, maxBytes, and source cacheOptions', () {
      final req = VGStreamingCachePrewarmPlanner.requestForSource(
        requestId: 'req-source-1',
        source: hlsSource,
        maxBytes: 1024 * 1024,
      );

      expect(req.requestId, equals('req-source-1'));
      expect(req.uri, equals(hlsSource.uri));
      expect(req.httpHeaders, equals({'X-Header': 'Val'}));
      expect(req.maxBytes, equals(1024 * 1024));
      expect(req.options.cacheMaxBytes, equals(64 * 1024 * 1024));
      expect(req.options.cacheDirectoryName, equals('source_cache'));
      expect(req.options.cacheEnabled, isTrue);
    });

    test('options parameter overrides source cacheOptions', () {
      const overrideOptions = VGPlaybackCacheOptions(
        cacheEnabled: true,
        cacheMaxBytes: 512 * 1024 * 1024,
        cacheDirectoryName: 'overridden_cache',
      );

      final req = VGStreamingCachePrewarmPlanner.requestForSource(
        requestId: 'req-source-2',
        source: hlsSource,
        options: overrideOptions,
      );

      expect(req.options.cacheMaxBytes, equals(512 * 1024 * 1024));
      expect(req.options.cacheDirectoryName, equals('overridden_cache'));
    });

    test(
      'uses default cache options when neither override nor source options exist',
      () {
        final plainSource = VGStreamingSourceDescriptor(
          key: 'plain',
          uri: Uri.parse('https://example.com/video.mp4'),
          initialWidth: 1920,
          initialHeight: 1080,
        );

        final req = VGStreamingCachePrewarmPlanner.requestForSource(
          requestId: 'req-plain',
          source: plainSource,
        );

        expect(req.options.cacheEnabled, isTrue);
        expect(req.options.cacheMaxBytes, isNull);
        expect(req.options.cacheDirectoryName, isNull);
      },
    );
  });

  group('VGStreamingCachePrewarmPlanner.planForSourceSet', () {
    final hlsSource = VGStreamingSourceDescriptor(
      key: 'hls',
      uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
      initialWidth: 1080,
      initialHeight: 1920,
      formatHint: VGStreamingFormatHint.hls,
    );

    final dashSource = VGStreamingSourceDescriptor(
      key: 'dash',
      uri: Uri.parse(
        'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
      ),
      initialWidth: 1080,
      initialHeight: 1920,
      formatHint: VGStreamingFormatHint.dash,
    );

    final llHlsSource = VGStreamingSourceDescriptor(
      key: 'll_hls',
      uri: Uri.parse(
        'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
      ),
      initialWidth: 1080,
      initialHeight: 1920,
      formatHint: VGStreamingFormatHint.hls,
      requireLlHlsTags: true,
    );

    final sourceSet = VGStreamingSourceSet(
      sources: [hlsSource, dashSource, llHlsSource],
    );

    test(
      'all-source ordering and deterministic IDs when sourceKeys is empty',
      () {
        final plan = VGStreamingCachePrewarmPlanner.planForSourceSet(
          sourceSet: sourceSet,
          requestIdPrefix: 'test_prefix',
          lowLatencyPolicy:
              VGStreamingCachePrewarmLowLatencyPolicy.allowBoundedManifestOnly,
        );

        expect(plan.requests.length, equals(3));
        expect(plan.requests[0].requestId, equals('test_prefix_hls_0'));
        expect(plan.requests[0].uri, equals(hlsSource.uri));
        expect(plan.requests[1].requestId, equals('test_prefix_dash_1'));
        expect(plan.requests[1].uri, equals(dashSource.uri));
        expect(plan.requests[2].requestId, equals('test_prefix_ll_hls_2'));
        expect(plan.requests[2].uri, equals(llHlsSource.uri));
        expect(plan.skippedKeys, isEmpty);
        expect(plan.warnings, isEmpty);
        expect(plan.diagnostics['requestCount'], equals(3));
        expect(plan.diagnostics['skippedCount'], equals(0));
        expect(plan.diagnostics['cacheEnabled'], isTrue);
      },
    );

    test('sourceKeys ordering and unknown key warning', () {
      final plan = VGStreamingCachePrewarmPlanner.planForSourceSet(
        sourceSet: sourceSet,
        requestIdPrefix: 'order_test',
        sourceKeys: ['dash', 'unknown_stream', 'hls'],
        lowLatencyPolicy:
            VGStreamingCachePrewarmLowLatencyPolicy.allowBoundedManifestOnly,
      );

      expect(plan.requests.length, equals(2));
      expect(plan.requests[0].requestId, equals('order_test_dash_0'));
      expect(plan.requests[0].uri, equals(dashSource.uri));
      expect(plan.requests[1].requestId, equals('order_test_hls_1'));
      expect(plan.requests[1].uri, equals(hlsSource.uri));
      expect(plan.warnings, contains('unknown_source_key:unknown_stream'));
    });

    test('low-latency skip behavior with skipLowLatency policy', () {
      final plan = VGStreamingCachePrewarmPlanner.planForSourceSet(
        sourceSet: sourceSet,
        requestIdPrefix: 'll_skip',
        sourceKeys: ['hls', 'll_hls'],
        lowLatencyPolicy:
            VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
      );

      expect(plan.requests.length, equals(1));
      expect(plan.requests.single.requestId, equals('ll_skip_hls_0'));
      expect(plan.skippedKeys, equals(['ll_hls']));
      expect(plan.warnings, contains('low_latency_cache_constrained:ll_hls'));
      expect(plan.diagnostics['skippedCount'], equals(1));
      expect(plan.diagnostics['lowLatencyPolicy'], equals('skipLowLatency'));
    });

    test('low-latency allow behavior with allowBoundedManifestOnly policy', () {
      final plan = VGStreamingCachePrewarmPlanner.planForSourceSet(
        sourceSet: sourceSet,
        requestIdPrefix: 'll_allow',
        sourceKeys: ['hls', 'll_hls'],
        lowLatencyPolicy:
            VGStreamingCachePrewarmLowLatencyPolicy.allowBoundedManifestOnly,
      );

      expect(plan.requests.length, equals(2));
      expect(plan.requests[0].requestId, equals('ll_allow_hls_0'));
      expect(plan.requests[1].requestId, equals('ll_allow_ll_hls_1'));
      expect(plan.skippedKeys, isEmpty);
      expect(plan.warnings, isEmpty);
      expect(
        plan.diagnostics['lowLatencyPolicy'],
        equals('allowBoundedManifestOnly'),
      );
    });

    test(
      'cache disabled returns no requests and marks keys skipped with warning',
      () {
        final plan = VGStreamingCachePrewarmPlanner.planForSourceSet(
          sourceSet: sourceSet,
          requestIdPrefix: 'disabled_test',
          sourceKeys: ['hls', 'dash', 'unknown_abc'],
          options: const VGPlaybackCacheOptions(cacheEnabled: false),
        );

        expect(plan.requests, isEmpty);
        expect(plan.hasRequests, isFalse);
        expect(plan.skippedKeys, equals(['hls', 'dash']));
        expect(plan.warnings, contains('cache_disabled'));
        expect(plan.warnings, contains('unknown_source_key:unknown_abc'));
        expect(plan.diagnostics['requestCount'], equals(0));
        expect(plan.diagnostics['skippedCount'], equals(2));
        expect(plan.diagnostics['cacheEnabled'], isFalse);
      },
    );

    test(
      'cache disabled with empty sourceKeys skips all sourceSet sources',
      () {
        final plan = VGStreamingCachePrewarmPlanner.planForSourceSet(
          sourceSet: sourceSet,
          requestIdPrefix: 'disabled_all',
          options: const VGPlaybackCacheOptions(cacheEnabled: false),
        );

        expect(plan.requests, isEmpty);
        expect(plan.skippedKeys, equals(['hls', 'dash', 'll_hls']));
        expect(plan.warnings, equals(['cache_disabled']));
      },
    );
  });

  group('VGStreamingCacheClientPrewarmRequest extension', () {
    test('prewarmRequest forwards exact args to MethodChannel route', () async {
      MethodCall? recordedCall;
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        recordedCall = call;
        if (call.method == 'startPlaybackCachePrewarm') {
          return <Object?, Object?>{
            'phase': 'Phase4C6E',
            'pass': true,
            'requestId': 'ext_req_101',
            'state': 'accepted',
            'raw': 'status=ACCEPTED',
          };
        }
        return null;
      });

      final client = VGStreamingCacheClient(channel: channel);
      final request = VGPlaybackPrewarmRequest(
        requestId: 'ext_req_101',
        uri: Uri.parse('https://example.com/video.mp4'),
        httpHeaders: const {'Header': 'Val'},
        maxBytes: 1048576,
        options: const VGPlaybackCacheOptions(
          cacheEnabled: true,
          cacheMaxBytes: 256 * 1024 * 1024,
          cacheDirectoryName: 'ext_cache',
        ),
      );

      final result = await client.prewarmRequest(request);

      expect(recordedCall, isNotNull);
      expect(recordedCall!.method, equals('startPlaybackCachePrewarm'));
      final callArgs = recordedCall!.arguments as Map;
      expect(callArgs['requestId'], equals('ext_req_101'));
      expect(callArgs['uri'], equals('https://example.com/video.mp4'));
      expect(callArgs['httpHeaders'], equals({'Header': 'Val'}));
      expect(callArgs['maxBytes'], equals(1048576));
      expect(callArgs['cacheEnabled'], isTrue);
      expect(callArgs['cacheMaxBytes'], equals(256 * 1024 * 1024));
      expect(callArgs['cacheDirectoryName'], equals('ext_cache'));

      expect(result.pass, isTrue);
      expect(result.requestId, equals('ext_req_101'));
      expect(result.state, equals(VGPlaybackPrewarmStartState.accepted));
    });
  });
}
