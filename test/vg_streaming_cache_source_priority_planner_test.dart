// Copyright (c) Connects — Vanguard Phase 4C6S.
// Public streaming source-set cache prewarm priority planner unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VGStreamingCacheSourcePriorityPlanRequest and planForSourceSet', () {
    VGStreamingSourceSet createTestSet() {
      return VGStreamingSourceSet(
        sources: [
          VGStreamingSourceDescriptor(
            key: 'source_hls',
            uri: Uri.parse('https://example.com/hls.m3u8'),
            initialWidth: 1080,
            initialHeight: 1920,
            httpHeaders: {'Authorization': 'Bearer token_hls'},
            cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
          ),
          VGStreamingSourceDescriptor(
            key: 'source_dash',
            uri: Uri.parse('https://example.com/dash.mpd'),
            initialWidth: 1080,
            initialHeight: 1920,
            httpHeaders: {'X-Custom': 'dash_header'},
            cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
          ),
          VGStreamingSourceDescriptor(
            key: 'source_ll_hls',
            uri: Uri.parse('https://example.com/ll.m3u8'),
            initialWidth: 1080,
            initialHeight: 1920,
            requireLlHlsTags: true,
            cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
          ),
          VGStreamingSourceDescriptor(
            key: 'source_backup',
            uri: Uri.parse('https://example.com/backup.m3u8'),
            initialWidth: 720,
            initialHeight: 1280,
            cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: true),
          ),
        ],
      );
    }

    test('request asserts on invalid parameters', () {
      final set = createTestSet();
      expect(
        () => VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: '',
        ),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'req',
          maxBytes: 0,
        ),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'req',
          defaultWeight: 0.0,
        ),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'req',
          defaultWeight: -1.0,
        ),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'req',
          maxTotalBytesBudget: -1,
        ),
        throwsAssertionError,
      );
      final valid = VGStreamingCacheSourcePriorityPlanRequest(
        sourceSet: set,
        requestIdPrefix: 'req_valid',
      );
      expect(valid.toString(), contains('req_valid'));
    });

    test(
      'admits requests in priority/weight order while preserving deterministic request IDs, URI/header/options, and low-latency metadata',
      () {
        final set = createTestSet();
        final request = VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'feed_hero',
          sourceKeys: ['source_hls', 'source_dash', 'source_backup'],
          maxBytes: 1024 * 1024,
          prioritiesBySourceKey: {
            'source_dash': VGStreamingCachePrewarmPriority.urgent,
            'source_hls': VGStreamingCachePrewarmPriority.normal,
            'source_backup': VGStreamingCachePrewarmPriority.urgent,
          },
          weightsBySourceKey: {'source_dash': 1.0, 'source_backup': 2.0},
          reasonsBySourceKey: {
            'source_dash': 'primary_dash',
            'source_backup': 'hero_backup',
          },
        );

        final plan = VGStreamingCachePriorityPlanner.planForSourceSet(request);

        // Expected candidate build order:
        // idx 0: source_hls -> requestId: feed_hero_source_hls_0, normal, w1.0
        // idx 1: source_dash -> requestId: feed_hero_source_dash_1, urgent, w1.0
        // idx 2: source_backup -> requestId: feed_hero_source_backup_2, urgent, w2.0
        //
        // Priority sort order:
        // 1. source_backup (urgent, w2.0) -> feed_hero_source_backup_2
        // 2. source_dash (urgent, w1.0) -> feed_hero_source_dash_1
        // 3. source_hls (normal, w1.0) -> feed_hero_source_hls_0
        expect(plan.admittedRequests.length, equals(3));
        expect(
          plan.admittedRequests[0].requestId,
          equals('feed_hero_source_backup_2'),
        );
        expect(
          plan.admittedRequests[0].uri,
          equals(Uri.parse('https://example.com/backup.m3u8')),
        );
        expect(plan.admittedRequests[0].maxBytes, equals(1024 * 1024));

        expect(
          plan.admittedRequests[1].requestId,
          equals('feed_hero_source_dash_1'),
        );
        expect(
          plan.admittedRequests[1].uri,
          equals(Uri.parse('https://example.com/dash.mpd')),
        );
        expect(
          plan.admittedRequests[1].httpHeaders,
          equals({'X-Custom': 'dash_header'}),
        );

        expect(
          plan.admittedRequests[2].requestId,
          equals('feed_hero_source_hls_0'),
        );
        expect(
          plan.admittedRequests[2].uri,
          equals(Uri.parse('https://example.com/hls.m3u8')),
        );
        expect(
          plan.admittedRequests[2].httpHeaders,
          equals({'Authorization': 'Bearer token_hls'}),
        );

        expect(plan.diagnostics['sourceCount'], equals(4));
        expect(plan.diagnostics['sourceKeysProvided'], isTrue);
        expect(plan.diagnostics['resolvedSourceCount'], equals(3));
        expect(plan.diagnostics['candidateCount'], equals(3));
        expect(plan.diagnostics['skippedSourceCount'], equals(0));
        expect(plan.diagnostics['requestIdPrefix'], equals('feed_hero'));
      },
    );

    test(
      'unknown source keys produce unknown_source_key:<key> warnings without creating candidates',
      () {
        final set = createTestSet();
        final request = VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'feed',
          sourceKeys: ['unknown_1', 'source_hls', 'unknown_2'],
        );

        final plan = VGStreamingCachePriorityPlanner.planForSourceSet(request);

        expect(plan.admittedRequests.length, equals(1));
        expect(plan.admittedRequests[0].requestId, equals('feed_source_hls_0'));
        expect(plan.warnings, contains('unknown_source_key:unknown_1'));
        expect(plan.warnings, contains('unknown_source_key:unknown_2'));
        expect(plan.diagnostics['resolvedSourceCount'], equals(1));
        expect(plan.diagnostics['candidateCount'], equals(1));
      },
    );

    test(
      'skipLowLatency skips LL-HLS sources before priority planning and records low_latency_cache_constrained:<key>',
      () {
        final set = createTestSet();
        final request = VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'feed_ll',
          lowLatencyPolicy:
              VGStreamingCachePrewarmLowLatencyPolicy.skipLowLatency,
        );

        final plan = VGStreamingCachePriorityPlanner.planForSourceSet(request);

        // Sources in set: source_hls (0), source_dash (1), source_ll_hls (2, skipped), source_backup (3)
        // Admitted count: 3
        expect(plan.admittedRequests.length, equals(3));
        expect(
          plan.warnings,
          contains('low_latency_cache_constrained:source_ll_hls'),
        );
        expect(plan.diagnostics['skippedSourceCount'], equals(1));
        expect(plan.diagnostics['candidateCount'], equals(3));
        expect(plan.diagnostics['resolvedSourceCount'], equals(4));
      },
    );

    test(
      'allowBoundedManifestOnly allows LL-HLS candidates through priority planning',
      () {
        final set = createTestSet();
        final request = VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'feed_ll_allow',
          lowLatencyPolicy:
              VGStreamingCachePrewarmLowLatencyPolicy.allowBoundedManifestOnly,
          prioritiesBySourceKey: {
            'source_ll_hls': VGStreamingCachePrewarmPriority.urgent,
          },
        );

        final plan = VGStreamingCachePriorityPlanner.planForSourceSet(request);

        expect(plan.admittedRequests.length, equals(4));
        expect(
          plan.admittedRequests[0].requestId,
          equals('feed_ll_allow_source_ll_hls_2'),
        );
        expect(plan.droppedCandidates, isEmpty);
        expect(plan.warnings, isEmpty);
        expect(plan.diagnostics['skippedSourceCount'], equals(0));
        expect(plan.diagnostics['allowLowLatency'], isTrue);
      },
    );

    test(
      'caller priority/weight maps determine ordering with defaults applied',
      () {
        final set = createTestSet();
        final request = VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'feed_defaults',
          sourceKeys: ['source_hls', 'source_dash'],
          defaultPriority: VGStreamingCachePrewarmPriority.low,
          defaultWeight: 3.0,
          prioritiesBySourceKey: {
            'source_dash': VGStreamingCachePrewarmPriority.high,
          },
        );

        final plan = VGStreamingCachePriorityPlanner.planForSourceSet(request);

        // source_dash gets high, defaultWeight (3.0) -> high rank 3
        // source_hls gets defaultPriority (low rank 1), defaultWeight (3.0)
        expect(plan.admittedRequests.length, equals(2));
        expect(
          plan.admittedRequests[0].requestId,
          equals('feed_defaults_source_dash_1'),
        );
        expect(
          plan.admittedRequests[1].requestId,
          equals('feed_defaults_source_hls_0'),
        );
      },
    );

    test(
      'budget and cache status behavior is preserved through the bridge',
      () {
        final set = createTestSet();
        const statusUnavailable = VGPlaybackCacheStatus(
          phase: 'Phase4C6E',
          pass: false,
          state: 'error',
          cacheAvailable: false,
          cacheEnabled: true,
          raw: '',
        );

        final requestUnavailable = VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'feed_unavail',
          sourceKeys: ['source_hls'],
          cacheStatus: statusUnavailable,
        );

        final planUnavailable =
            VGStreamingCachePriorityPlanner.planForSourceSet(
              requestUnavailable,
            );
        expect(planUnavailable.admittedRequests, isEmpty);
        expect(planUnavailable.droppedCandidates.length, equals(1));
        expect(
          planUnavailable.droppedCandidates.single.reason,
          equals('cache_unavailable'),
        );

        // Budget test
        final requestBudget = VGStreamingCacheSourcePriorityPlanRequest(
          sourceSet: set,
          requestIdPrefix: 'feed_budget',
          sourceKeys: ['source_hls', 'source_dash'],
          maxBytes: 1000,
          maxTotalBytesBudget: 1500,
        );

        final planBudget = VGStreamingCachePriorityPlanner.planForSourceSet(
          requestBudget,
        );
        expect(planBudget.admittedRequests.length, equals(1));
        expect(planBudget.droppedCandidates.length, equals(1));
        expect(
          planBudget.droppedCandidates.single.reason,
          equals('budget_exceeded'),
        );
      },
    );

    test('returned collections and request collections are unmodifiable', () {
      final set = createTestSet();
      final mutableKeys = ['source_hls'];
      final mutablePriorities = {
        'source_hls': VGStreamingCachePrewarmPriority.urgent,
      };
      final mutableWeights = {'source_hls': 1.5};
      final mutableReasons = {'source_hls': 'reason_1'};

      final request = VGStreamingCacheSourcePriorityPlanRequest(
        sourceSet: set,
        requestIdPrefix: 'imm_test',
        sourceKeys: mutableKeys,
        prioritiesBySourceKey: mutablePriorities,
        weightsBySourceKey: mutableWeights,
        reasonsBySourceKey: mutableReasons,
      );

      expect(
        () => request.sourceKeys.add('source_dash'),
        throwsUnsupportedError,
      );
      expect(
        () => request.prioritiesBySourceKey['k'] =
            VGStreamingCachePrewarmPriority.normal,
        throwsUnsupportedError,
      );
      expect(
        () => request.weightsBySourceKey['k'] = 2.0,
        throwsUnsupportedError,
      );
      expect(
        () => request.reasonsBySourceKey['k'] = 'r',
        throwsUnsupportedError,
      );

      final plan = VGStreamingCachePriorityPlanner.planForSourceSet(request);
      expect(
        () => plan.admittedRequests.add(
          VGPlaybackPrewarmRequest(
            requestId: 'x',
            uri: Uri.parse('https://example.com'),
          ),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => plan.droppedCandidates.add(
          VGStreamingCacheDroppedPrewarmCandidate(
            candidate: VGStreamingCachePrewarmCandidate(
              request: VGPlaybackPrewarmRequest(
                requestId: 'x',
                uri: Uri.parse('https://example.com'),
              ),
            ),
            reason: 'r',
          ),
        ),
        throwsUnsupportedError,
      );
      expect(() => plan.warnings.add('w'), throwsUnsupportedError);
      expect(() => plan.diagnostics['k'] = 'v', throwsUnsupportedError);
    });
  });
}
