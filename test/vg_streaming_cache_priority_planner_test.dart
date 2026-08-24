// Copyright (c) Connects — Vanguard Phase 4C6R.
// Public streaming cache prewarm priority planner unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  VGPlaybackPrewarmRequest createRequest({
    required String requestId,
    int maxBytes = 2 * 1024 * 1024,
    bool cacheEnabled = true,
  }) {
    return VGPlaybackPrewarmRequest(
      requestId: requestId,
      uri: Uri.parse('https://example.com/stream_$requestId.m3u8'),
      maxBytes: maxBytes,
      options: VGPlaybackCacheOptions(cacheEnabled: cacheEnabled),
    );
  }

  group('VGStreamingCachePrewarmPriority and Candidates', () {
    test('priority ranks are ordered urgent > high > normal > low', () {
      expect(
        VGStreamingCachePrewarmPriority.urgent.rank >
            VGStreamingCachePrewarmPriority.high.rank,
        isTrue,
      );
      expect(
        VGStreamingCachePrewarmPriority.high.rank >
            VGStreamingCachePrewarmPriority.normal.rank,
        isTrue,
      );
      expect(
        VGStreamingCachePrewarmPriority.normal.rank >
            VGStreamingCachePrewarmPriority.low.rank,
        isTrue,
      );
    });

    test('candidate asserts on weight <= 0', () {
      final req = createRequest(requestId: 'c1');
      expect(
        () => VGStreamingCachePrewarmCandidate(request: req, weight: 0.0),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingCachePrewarmCandidate(request: req, weight: -0.5),
        throwsAssertionError,
      );
      final valid = VGStreamingCachePrewarmCandidate(request: req, weight: 1.5);
      expect(valid.toString(), contains('c1'));
    });

    test('dropped candidate toString formats expected info', () {
      final req = createRequest(requestId: 'drop_1');
      final cand = VGStreamingCachePrewarmCandidate(request: req);
      final dropped = VGStreamingCacheDroppedPrewarmCandidate(
        candidate: cand,
        reason: 'test_reason',
      );
      expect(dropped.toString(), contains('drop_1'));
      expect(dropped.toString(), contains('test_reason'));
    });
  });

  group('VGStreamingCacheEvictionAdvisory', () {
    test(
      'asserts on invalid negative or non-positive maxCacheBytes values',
      () {
        expect(
          () => VGStreamingCacheEvictionAdvisory(
            recommendedBytesToFree: -1,
            currentCacheSpaceBytes: 100,
            maxCacheBytes: 200,
            requestedAdmitBytes: 100,
            rationale: 'r',
          ),
          throwsAssertionError,
        );
        expect(
          () => VGStreamingCacheEvictionAdvisory(
            recommendedBytesToFree: 50,
            currentCacheSpaceBytes: -1,
            maxCacheBytes: 200,
            requestedAdmitBytes: 100,
            rationale: 'r',
          ),
          throwsAssertionError,
        );
        expect(
          () => VGStreamingCacheEvictionAdvisory(
            recommendedBytesToFree: 50,
            currentCacheSpaceBytes: 100,
            maxCacheBytes: 0,
            requestedAdmitBytes: 100,
            rationale: 'r',
          ),
          throwsAssertionError,
        );
        expect(
          () => VGStreamingCacheEvictionAdvisory(
            recommendedBytesToFree: 50,
            currentCacheSpaceBytes: 100,
            maxCacheBytes: 200,
            requestedAdmitBytes: -1,
            rationale: 'r',
          ),
          throwsAssertionError,
        );
      },
    );

    test('toJson and toString serialize fields correctly', () {
      final adv = VGStreamingCacheEvictionAdvisory(
        recommendedBytesToFree: 500,
        currentCacheSpaceBytes: 1500,
        maxCacheBytes: 1000,
        requestedAdmitBytes: 600,
        rationale: 'overflow test',
      );
      final json = adv.toJson();
      expect(json['recommendedBytesToFree'], equals(500));
      expect(json['currentCacheSpaceBytes'], equals(1500));
      expect(json['maxCacheBytes'], equals(1000));
      expect(json['requestedAdmitBytes'], equals(600));
      expect(json['rationale'], equals('overflow test'));
      expect(adv.toString(), contains('500'));
    });
  });

  group('VGStreamingCachePriorityPlanner behavior', () {
    test('1. priority/weight ordering and stable original-index tie break', () {
      final r1 = createRequest(requestId: 'req_normal_1');
      final r2 = createRequest(requestId: 'req_urgent_w1');
      final r3 = createRequest(requestId: 'req_high_w2');
      final r4 = createRequest(requestId: 'req_high_w1');
      final r5 = createRequest(requestId: 'req_urgent_w2');
      final r6 = createRequest(requestId: 'req_normal_2');

      final candidates = [
        VGStreamingCachePrewarmCandidate(
          request: r1,
          priority: VGStreamingCachePrewarmPriority.normal,
          weight: 1.0,
        ), // idx 0
        VGStreamingCachePrewarmCandidate(
          request: r2,
          priority: VGStreamingCachePrewarmPriority.urgent,
          weight: 1.0,
        ), // idx 1
        VGStreamingCachePrewarmCandidate(
          request: r3,
          priority: VGStreamingCachePrewarmPriority.high,
          weight: 2.0,
        ), // idx 2
        VGStreamingCachePrewarmCandidate(
          request: r4,
          priority: VGStreamingCachePrewarmPriority.high,
          weight: 1.0,
        ), // idx 3
        VGStreamingCachePrewarmCandidate(
          request: r5,
          priority: VGStreamingCachePrewarmPriority.urgent,
          weight: 2.0,
        ), // idx 4
        VGStreamingCachePrewarmCandidate(
          request: r6,
          priority: VGStreamingCachePrewarmPriority.normal,
          weight: 1.0,
        ), // idx 5
      ];

      final plan = VGStreamingCachePriorityPlanner.plan(candidates: candidates);

      // Expected order:
      // 1. req_urgent_w2 (urgent, w2)
      // 2. req_urgent_w1 (urgent, w1)
      // 3. req_high_w2 (high, w2)
      // 4. req_high_w1 (high, w1)
      // 5. req_normal_1 (normal, w1, original index 0)
      // 6. req_normal_2 (normal, w1, original index 5)
      expect(plan.admittedRequests.length, equals(6));
      expect(plan.admittedRequests[0].requestId, equals('req_urgent_w2'));
      expect(plan.admittedRequests[1].requestId, equals('req_urgent_w1'));
      expect(plan.admittedRequests[2].requestId, equals('req_high_w2'));
      expect(plan.admittedRequests[3].requestId, equals('req_high_w1'));
      expect(plan.admittedRequests[4].requestId, equals('req_normal_1'));
      expect(plan.admittedRequests[5].requestId, equals('req_normal_2'));
      expect(plan.droppedCandidates, isEmpty);
      expect(plan.warnings, isEmpty);
    });

    test('2. max total bytes budget drops overflow candidates', () {
      final r1 = createRequest(requestId: 'r1', maxBytes: 1000);
      final r2 = createRequest(requestId: 'r2', maxBytes: 1500);
      final r3 = createRequest(requestId: 'r3', maxBytes: 800);

      final candidates = [
        VGStreamingCachePrewarmCandidate(
          request: r1,
          priority: VGStreamingCachePrewarmPriority.urgent,
        ),
        VGStreamingCachePrewarmCandidate(
          request: r2,
          priority: VGStreamingCachePrewarmPriority.high,
        ),
        VGStreamingCachePrewarmCandidate(
          request: r3,
          priority: VGStreamingCachePrewarmPriority.normal,
        ),
      ];

      final plan = VGStreamingCachePriorityPlanner.plan(
        candidates: candidates,
        maxTotalBytesBudget: 2000,
      );

      // r1 (1000) admitted -> total 1000
      // r2 (1500) exceeds 2000 (1000+1500=2500) -> dropped with budget_exceeded
      // r3 (800) fits (1000+800=1800 <= 2000) -> admitted
      expect(plan.admittedRequests.length, equals(2));
      expect(plan.admittedRequests[0].requestId, equals('r1'));
      expect(plan.admittedRequests[1].requestId, equals('r3'));
      expect(plan.totalAdmittedBytes, equals(1800));
      expect(plan.totalRequestedBytes, equals(3300));
      expect(plan.droppedCandidates.length, equals(1));
      expect(
        plan.droppedCandidates[0].candidate.request.requestId,
        equals('r2'),
      );
      expect(plan.droppedCandidates[0].reason, equals('budget_exceeded'));
    });

    test(
      '3. duplicate request IDs keep stronger candidate and warn/drop duplicate',
      () {
        final reqLow = createRequest(requestId: 'dup_req', maxBytes: 1000);
        final reqHigh = createRequest(requestId: 'dup_req', maxBytes: 2000);
        final reqUrgent = createRequest(requestId: 'dup_req', maxBytes: 3000);
        final reqUrgentTie = createRequest(
          requestId: 'dup_req',
          maxBytes: 4000,
        );

        final candidates = [
          VGStreamingCachePrewarmCandidate(
            request: reqLow,
            priority: VGStreamingCachePrewarmPriority.low,
            weight: 1.0,
          ),
          VGStreamingCachePrewarmCandidate(
            request: reqHigh,
            priority: VGStreamingCachePrewarmPriority.high,
            weight: 1.0,
          ),
          VGStreamingCachePrewarmCandidate(
            request: reqUrgent,
            priority: VGStreamingCachePrewarmPriority.urgent,
            weight: 2.0,
          ),
          VGStreamingCachePrewarmCandidate(
            request: reqUrgentTie,
            priority: VGStreamingCachePrewarmPriority.urgent,
            weight: 2.0,
          ),
        ];

        final plan = VGStreamingCachePriorityPlanner.plan(
          candidates: candidates,
        );

        expect(plan.admittedRequests.length, equals(1));
        expect(plan.admittedRequests.single.maxBytes, equals(3000));
        expect(plan.totalRequestedBytes, equals(3000));
        expect(plan.droppedCandidates.length, equals(3));
        expect(
          plan.droppedCandidates.every(
            (d) => d.reason == 'duplicate_request_id:dup_req',
          ),
          isTrue,
        );
        expect(plan.warnings, contains('duplicate_request_id:dup_req'));
        expect(plan.diagnostics['candidateCount'], equals(4));
        expect(plan.diagnostics['uniqueCandidateCount'], equals(1));
      },
    );

    test('4. request-level cache disabled drops candidate', () {
      final r1 = createRequest(requestId: 'enabled_req', cacheEnabled: true);
      final r2 = createRequest(requestId: 'disabled_req', cacheEnabled: false);

      final candidates = [
        VGStreamingCachePrewarmCandidate(request: r1),
        VGStreamingCachePrewarmCandidate(request: r2),
      ];

      final plan = VGStreamingCachePriorityPlanner.plan(candidates: candidates);

      expect(plan.admittedRequests.length, equals(1));
      expect(plan.admittedRequests.single.requestId, equals('enabled_req'));
      expect(plan.droppedCandidates.length, equals(1));
      expect(
        plan.droppedCandidates.single.reason,
        equals('cache_disabled:disabled_req'),
      );
      expect(plan.warnings, contains('cache_disabled:disabled_req'));
    });

    test('5. low-latency skip vs allow using explicit isLowLatency', () {
      final rNormal = createRequest(requestId: 'stream_vod');
      final rLl = createRequest(requestId: 'stream_ll');

      final candidates = [
        VGStreamingCachePrewarmCandidate(request: rNormal, isLowLatency: false),
        VGStreamingCachePrewarmCandidate(request: rLl, isLowLatency: true),
      ];

      // Disallow low latency
      final planDisallowed = VGStreamingCachePriorityPlanner.plan(
        candidates: candidates,
        allowLowLatency: false,
      );
      expect(planDisallowed.admittedRequests.length, equals(1));
      expect(
        planDisallowed.admittedRequests.single.requestId,
        equals('stream_vod'),
      );
      expect(planDisallowed.droppedCandidates.length, equals(1));
      expect(
        planDisallowed.droppedCandidates.single.reason,
        equals('low_latency_cache_constrained:stream_ll'),
      );
      expect(
        planDisallowed.warnings,
        contains('low_latency_cache_constrained:stream_ll'),
      );

      // Allow low latency
      final planAllowed = VGStreamingCachePriorityPlanner.plan(
        candidates: candidates,
        allowLowLatency: true,
      );
      expect(planAllowed.admittedRequests.length, equals(2));
      expect(planAllowed.droppedCandidates, isEmpty);
      expect(planAllowed.warnings, isEmpty);
    });

    test(
      '6. cacheStatus disabled/unavailable drops all otherwise-valid candidates',
      () {
        final r1 = createRequest(requestId: 'r1');
        final r2 = createRequest(requestId: 'r2');
        final candidates = [
          VGStreamingCachePrewarmCandidate(request: r1),
          VGStreamingCachePrewarmCandidate(request: r2),
        ];

        const statusDisabled = VGPlaybackCacheStatus(
          phase: 'Phase4C6E',
          pass: true,
          state: 'available',
          cacheAvailable: true,
          cacheEnabled: false,
          raw: 'cacheEnabled=false',
        );

        final planDisabled = VGStreamingCachePriorityPlanner.plan(
          candidates: candidates,
          cacheStatus: statusDisabled,
        );

        expect(planDisabled.admittedRequests, isEmpty);
        expect(planDisabled.hasRequests, isFalse);
        expect(planDisabled.droppedCandidates.length, equals(2));
        expect(
          planDisabled.droppedCandidates.every(
            (d) => d.reason == 'cache_status_disabled',
          ),
          isTrue,
        );

        const statusUnavailable = VGPlaybackCacheStatus(
          phase: 'Phase4C6E',
          pass: false,
          state: 'error',
          cacheAvailable: false,
          cacheEnabled: true,
          raw: 'cacheAvailable=false',
        );

        final planUnavailable = VGStreamingCachePriorityPlanner.plan(
          candidates: candidates,
          cacheStatus: statusUnavailable,
        );

        expect(planUnavailable.admittedRequests, isEmpty);
        expect(planUnavailable.hasRequests, isFalse);
        expect(planUnavailable.droppedCandidates.length, equals(2));
        expect(
          planUnavailable.droppedCandidates.every(
            (d) => d.reason == 'cache_unavailable',
          ),
          isTrue,
        );
      },
    );

    test(
      '7. eviction advisory when admitted bytes plus existing cache space exceed max',
      () {
        final r1 = createRequest(requestId: 'r1', maxBytes: 300 * 1024);
        final r2 = createRequest(requestId: 'r2', maxBytes: 400 * 1024);

        final candidates = [
          VGStreamingCachePrewarmCandidate(request: r1),
          VGStreamingCachePrewarmCandidate(request: r2),
        ];

        const statusWithOverflow = VGPlaybackCacheStatus(
          phase: 'Phase4C6E',
          pass: true,
          state: 'available',
          cacheAvailable: true,
          cacheEnabled: true,
          cacheSpaceBytes: 500 * 1024,
          maxCacheBytes: 1000 * 1024,
          raw: '',
        );

        final plan = VGStreamingCachePriorityPlanner.plan(
          candidates: candidates,
          cacheStatus: statusWithOverflow,
        );

        // Admitted: 700KB. Total with cacheSpaceBytes = 500KB + 700KB = 1200KB.
        // Max: 1000KB. Overflow = 200KB.
        expect(plan.admittedRequests.length, equals(2));
        expect(plan.hasEvictionAdvisory, isTrue);
        expect(plan.evictionAdvisory, isNotNull);
        expect(
          plan.evictionAdvisory!.recommendedBytesToFree,
          equals(200 * 1024),
        );
        expect(
          plan.evictionAdvisory!.currentCacheSpaceBytes,
          equals(500 * 1024),
        );
        expect(plan.evictionAdvisory!.maxCacheBytes, equals(1000 * 1024));
        expect(plan.evictionAdvisory!.requestedAdmitBytes, equals(700 * 1024));
        expect(plan.diagnostics['evictionRecommended'], isTrue);

        // Verify when no overflow:
        const statusNoOverflow = VGPlaybackCacheStatus(
          phase: 'Phase4C6E',
          pass: true,
          state: 'available',
          cacheAvailable: true,
          cacheEnabled: true,
          cacheSpaceBytes: 200 * 1024,
          maxCacheBytes: 1000 * 1024,
          raw: '',
        );

        final planNoOverflow = VGStreamingCachePriorityPlanner.plan(
          candidates: candidates,
          cacheStatus: statusNoOverflow,
        );
        expect(planNoOverflow.hasEvictionAdvisory, isFalse);
        expect(planNoOverflow.evictionAdvisory, isNull);
        expect(planNoOverflow.diagnostics['evictionRecommended'], isFalse);
      },
    );

    test('8. zero budget admits none', () {
      final r1 = createRequest(requestId: 'r1', maxBytes: 1024);
      final candidates = [VGStreamingCachePrewarmCandidate(request: r1)];

      final plan = VGStreamingCachePriorityPlanner.plan(
        candidates: candidates,
        maxTotalBytesBudget: 0,
      );

      expect(plan.admittedRequests, isEmpty);
      expect(plan.totalAdmittedBytes, equals(0));
      expect(plan.totalRequestedBytes, equals(1024));
      expect(plan.droppedCandidates.length, equals(1));
      expect(plan.droppedCandidates.single.reason, equals('budget_exceeded'));
    });

    test('9. immutable result collections cannot be mutated', () {
      final r1 = createRequest(requestId: 'r1');
      final candidates = [VGStreamingCachePrewarmCandidate(request: r1)];

      final plan = VGStreamingCachePriorityPlanner.plan(candidates: candidates);

      expect(
        () => plan.admittedRequests.add(createRequest(requestId: 'r2')),
        throwsUnsupportedError,
      );
      expect(
        () => plan.droppedCandidates.add(
          VGStreamingCacheDroppedPrewarmCandidate(
            candidate: candidates.first,
            reason: 'mut',
          ),
        ),
        throwsUnsupportedError,
      );
      expect(() => plan.warnings.add('new_warning'), throwsUnsupportedError);
      expect(() => plan.diagnostics['new_key'] = 1, throwsUnsupportedError);
    });

    test('budget assertion catches negative budget', () {
      expect(
        () => VGStreamingCachePriorityPlanner.plan(
          candidates: [],
          maxTotalBytesBudget: -1,
        ),
        throwsAssertionError,
      );
    });
  });
}
