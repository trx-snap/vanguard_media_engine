// Copyright (c) Connects — Vanguard Phase 4C7BF.
// Public streaming offline asset acquisition request planner unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingOfflineAssetAcquisitionPlanner', () {
    final candidateHlsMain = VGStreamingOfflineAssetCandidate(
      sourceKey: 'hls_main',
      uri: Uri.parse('https://example.com/main.m3u8'),
      httpHeaders: const {'Authorization': 'Bearer test-token'},
      formatHint: VGStreamingFormatHint.hls,
      requireLlHlsTags: false,
    );

    final candidateHlsSecondary = VGStreamingOfflineAssetCandidate(
      sourceKey: 'hls_secondary',
      uri: Uri.parse('https://example.com/secondary.m3u8'),
      formatHint: VGStreamingFormatHint.hls,
    );

    final candidateHlsTertiary = VGStreamingOfflineAssetCandidate(
      sourceKey: 'hls_tertiary',
      uri: Uri.parse('https://example.com/tertiary.m3u8'),
      formatHint: VGStreamingFormatHint.hls,
    );

    test(
      'Empty eligibility plan yields empty request plan and preserves warnings/diagnostics',
      () {
        final eligibilityPlan = VGStreamingOfflineAssetEligibilityPlan(
          candidates: const [],
          rejectedSources: [
            VGStreamingOfflineAssetRejectedSource(
              sourceKey: 'dash_rejected',
              state: VGStreamingOfflineAssetEligibilityState.unsupportedFormat,
              reason: 'dash_offline_deferred',
            ),
          ],
          warnings: const [
            'offline_rejected:dash_rejected:dash_offline_deferred',
          ],
        );

        final plan = VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: eligibilityPlan,
          requestIdPrefix: 'req_offline',
          maxTotalEstimatedBytesBudget: 100 * 1024 * 1024,
        );

        expect(plan.hasRequests, isFalse);
        expect(plan.hasDrops, isFalse);
        expect(plan.requests, isEmpty);
        expect(plan.droppedCandidates, isEmpty);
        expect(plan.totalEstimatedBytes, equals(0));
        expect(
          plan.warnings,
          contains('offline_rejected:dash_rejected:dash_offline_deferred'),
        );
        expect(plan.diagnostics['candidateCount'], equals(0));
        expect(plan.diagnostics['eligibilityCandidateCount'], equals(0));
        expect(plan.diagnostics['eligibilityRejectedCount'], equals(1));
        expect(plan.diagnostics['requestCount'], equals(0));
        expect(plan.diagnostics['droppedCount'], equals(0));
        expect(plan.diagnostics['totalEstimatedBytes'], equals(0));
        expect(
          plan.diagnostics['maxTotalEstimatedBytesBudget'],
          equals(100 * 1024 * 1024),
        );
        expect(plan.diagnostics['advisoryOnly'], isTrue);
        expect(plan.diagnostics['playbackMutation'], isFalse);
      },
    );

    test(
      'Single HLS candidate becomes acquisition request with deterministic id and toArgs values',
      () {
        final eligibilityPlan = VGStreamingOfflineAssetEligibilityPlan(
          candidates: [candidateHlsMain],
        );

        final plan = VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: eligibilityPlan,
          requestIdPrefix: 'offline_acquire',
          defaultEstimatedBytes: 32 * 1024 * 1024,
          defaultPriority: VGStreamingOfflineAssetAcquisitionPriority.normal,
        );

        expect(plan.hasRequests, isTrue);
        expect(plan.hasDrops, isFalse);
        expect(plan.requests, hasLength(1));

        final req = plan.requests.single;
        expect(req.requestId, equals('offline_acquire_hls_main_0'));
        expect(req.sourceKey, equals('hls_main'));
        expect(req.uri, equals(Uri.parse('https://example.com/main.m3u8')));
        expect(req.formatHint, equals(VGStreamingFormatHint.hls));
        expect(req.requireLlHlsTags, isFalse);
        expect(req.estimatedBytes, equals(32 * 1024 * 1024));
        expect(
          req.priority,
          equals(VGStreamingOfflineAssetAcquisitionPriority.normal),
        );
        expect(req.reason, isNull);

        final args = req.toArgs();
        expect(args['requestId'], equals('offline_acquire_hls_main_0'));
        expect(args['sourceKey'], equals('hls_main'));
        expect(args['uri'], equals('https://example.com/main.m3u8'));
        expect(
          args['httpHeaders'],
          equals({'Authorization': 'Bearer test-token'}),
        );
        expect(args['formatHint'], equals('HLS'));
        expect(args['requireLlHlsTags'], isFalse);
        expect(args['estimatedBytes'], equals(32 * 1024 * 1024));
        expect(args['priority'], equals('normal'));
        expect(args.containsKey('reason'), isFalse);

        expect(plan.totalEstimatedBytes, equals(32 * 1024 * 1024));
        expect(plan.diagnostics['requestCount'], equals(1));
        expect(plan.diagnostics['droppedCount'], equals(0));
        expect(plan.diagnostics['candidateCount'], equals(1));
      },
    );

    test('HTTP headers are immutable and preserved', () {
      final req = VGStreamingOfflineAssetAcquisitionRequest(
        requestId: 'req_1',
        sourceKey: 'source_1',
        uri: Uri.parse('https://example.com/stream.m3u8'),
        httpHeaders: {'Custom-Header': 'Value'},
        estimatedBytes: 1000,
      );

      expect(req.httpHeaders, equals({'Custom-Header': 'Value'}));
      expect(
        () => req.httpHeaders!['Another-Header'] = 'Another-Value',
        throwsUnsupportedError,
      );
    });

    test(
      'Priority sorting urgent/high/normal/low with stable original-index tie break',
      () {
        final cand0 = VGStreamingOfflineAssetCandidate(
          sourceKey: 'source_a',
          uri: Uri.parse('https://example.com/a.m3u8'),
        );
        final cand1 = VGStreamingOfflineAssetCandidate(
          sourceKey: 'source_b',
          uri: Uri.parse('https://example.com/b.m3u8'),
        );
        final cand2 = VGStreamingOfflineAssetCandidate(
          sourceKey: 'source_c',
          uri: Uri.parse('https://example.com/c.m3u8'),
        );
        final cand3 = VGStreamingOfflineAssetCandidate(
          sourceKey: 'source_d',
          uri: Uri.parse('https://example.com/d.m3u8'),
        );
        final cand4 = VGStreamingOfflineAssetCandidate(
          sourceKey: 'source_e',
          uri: Uri.parse('https://example.com/e.m3u8'),
        );

        final eligibilityPlan = VGStreamingOfflineAssetEligibilityPlan(
          candidates: [cand0, cand1, cand2, cand3, cand4],
        );

        final plan = VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: eligibilityPlan,
          requestIdPrefix: 'batch',
          prioritiesBySourceKey: {
            'source_a': VGStreamingOfflineAssetAcquisitionPriority.low,
            'source_b': VGStreamingOfflineAssetAcquisitionPriority.urgent,
            'source_c': VGStreamingOfflineAssetAcquisitionPriority.high,
            'source_d': VGStreamingOfflineAssetAcquisitionPriority.high,
            'source_e': VGStreamingOfflineAssetAcquisitionPriority.normal,
          },
        );

        expect(plan.requests, hasLength(5));
        // Order should be:
        // 1. source_b (urgent - rank 4, original index 1)
        // 2. source_c (high - rank 3, original index 2)
        // 3. source_d (high - rank 3, original index 3) -> stable tie break with source_c
        // 4. source_e (normal - rank 2, original index 4)
        // 5. source_a (low - rank 1, original index 0)
        expect(plan.requests[0].sourceKey, equals('source_b'));
        expect(plan.requests[0].requestId, equals('batch_source_b_1'));
        expect(
          plan.requests[0].priority,
          equals(VGStreamingOfflineAssetAcquisitionPriority.urgent),
        );

        expect(plan.requests[1].sourceKey, equals('source_c'));
        expect(plan.requests[1].requestId, equals('batch_source_c_2'));
        expect(
          plan.requests[1].priority,
          equals(VGStreamingOfflineAssetAcquisitionPriority.high),
        );

        expect(plan.requests[2].sourceKey, equals('source_d'));
        expect(plan.requests[2].requestId, equals('batch_source_d_3'));
        expect(
          plan.requests[2].priority,
          equals(VGStreamingOfflineAssetAcquisitionPriority.high),
        );

        expect(plan.requests[3].sourceKey, equals('source_e'));
        expect(plan.requests[3].requestId, equals('batch_source_e_4'));
        expect(
          plan.requests[3].priority,
          equals(VGStreamingOfflineAssetAcquisitionPriority.normal),
        );

        expect(plan.requests[4].sourceKey, equals('source_a'));
        expect(plan.requests[4].requestId, equals('batch_source_a_0'));
        expect(
          plan.requests[4].priority,
          equals(VGStreamingOfflineAssetAcquisitionPriority.low),
        );
      },
    );

    test('Estimated byte overrides and reason overrides are applied', () {
      final eligibilityPlan = VGStreamingOfflineAssetEligibilityPlan(
        candidates: [candidateHlsMain, candidateHlsSecondary],
      );

      final plan = VGStreamingOfflineAssetAcquisitionPlanner.plan(
        eligibilityPlan: eligibilityPlan,
        requestIdPrefix: 'custom',
        defaultEstimatedBytes: 50 * 1024 * 1024,
        estimatedBytesBySourceKey: {'hls_main': 120 * 1024 * 1024},
        reasonsBySourceKey: {
          'hls_main': 'primary_vod_feature',
          'hls_secondary': 'fallback_rendition',
        },
      );

      expect(plan.requests, hasLength(2));
      expect(plan.requests[0].sourceKey, equals('hls_main'));
      expect(plan.requests[0].estimatedBytes, equals(120 * 1024 * 1024));
      expect(plan.requests[0].reason, equals('primary_vod_feature'));
      expect(
        plan.requests[0].toArgs()['reason'],
        equals('primary_vod_feature'),
      );

      expect(plan.requests[1].sourceKey, equals('hls_secondary'));
      expect(plan.requests[1].estimatedBytes, equals(50 * 1024 * 1024));
      expect(plan.requests[1].reason, equals('fallback_rendition'));
      expect(plan.requests[1].toArgs()['reason'], equals('fallback_rendition'));

      expect(plan.totalEstimatedBytes, equals(170 * 1024 * 1024));
    });

    test(
      'maxTotalEstimatedBytesBudget drops overflow candidates and warning is emitted',
      () {
        final eligibilityPlan = VGStreamingOfflineAssetEligibilityPlan(
          candidates: [
            candidateHlsMain,
            candidateHlsSecondary,
            candidateHlsTertiary,
          ],
        );

        // All 3 candidates are 40MB by default = 120MB total.
        // Budget is 70MB.
        // Candidate 0: 40MB -> admitted (cumulative 40MB)
        // Candidate 1: 40MB -> cumulative would be 80MB > 70MB -> dropped with reason estimated_budget_exceeded
        // Candidate 2: 40MB -> cumulative would be 80MB > 70MB -> dropped with reason estimated_budget_exceeded
        final plan = VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: eligibilityPlan,
          requestIdPrefix: 'budget_test',
          defaultEstimatedBytes: 40 * 1024 * 1024,
          maxTotalEstimatedBytesBudget: 70 * 1024 * 1024,
        );

        expect(plan.hasRequests, isTrue);
        expect(plan.hasDrops, isTrue);
        expect(plan.requests, hasLength(1));
        expect(plan.requests.single.sourceKey, equals('hls_main'));
        expect(plan.totalEstimatedBytes, equals(40 * 1024 * 1024));

        expect(plan.droppedCandidates, hasLength(2));
        expect(
          plan.droppedCandidates[0].candidate.sourceKey,
          equals('hls_secondary'),
        );
        expect(
          plan.droppedCandidates[0].reason,
          equals('estimated_budget_exceeded'),
        );
        expect(
          plan.droppedCandidates[1].candidate.sourceKey,
          equals('hls_tertiary'),
        );
        expect(
          plan.droppedCandidates[1].reason,
          equals('estimated_budget_exceeded'),
        );

        expect(
          plan.warnings,
          contains(
            'offline_acquisition_dropped:hls_secondary:estimated_budget_exceeded',
          ),
        );
        expect(
          plan.warnings,
          contains(
            'offline_acquisition_dropped:hls_tertiary:estimated_budget_exceeded',
          ),
        );
        expect(plan.diagnostics['droppedCount'], equals(2));
        expect(plan.diagnostics['requestCount'], equals(1));
      },
    );

    test('Zero budget drops all candidates', () {
      final eligibilityPlan = VGStreamingOfflineAssetEligibilityPlan(
        candidates: [candidateHlsMain, candidateHlsSecondary],
      );

      final plan = VGStreamingOfflineAssetAcquisitionPlanner.plan(
        eligibilityPlan: eligibilityPlan,
        requestIdPrefix: 'zero_budget',
        defaultEstimatedBytes: 10 * 1024 * 1024,
        maxTotalEstimatedBytesBudget: 0,
      );

      expect(plan.hasRequests, isFalse);
      expect(plan.hasDrops, isTrue);
      expect(plan.requests, isEmpty);
      expect(plan.droppedCandidates, hasLength(2));
      expect(plan.totalEstimatedBytes, equals(0));
      expect(
        plan.warnings,
        contains(
          'offline_acquisition_dropped:hls_main:estimated_budget_exceeded',
        ),
      );
      expect(
        plan.warnings,
        contains(
          'offline_acquisition_dropped:hls_secondary:estimated_budget_exceeded',
        ),
      );
    });

    test('Constructor and assertion validation', () {
      // VGStreamingOfflineAssetAcquisitionRequest assertions
      expect(
        () => VGStreamingOfflineAssetAcquisitionRequest(
          requestId: '',
          sourceKey: 'valid_key',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          estimatedBytes: 1000,
        ),
        throwsA(isA<AssertionError>()),
      );

      expect(
        () => VGStreamingOfflineAssetAcquisitionRequest(
          requestId: 'valid_id',
          sourceKey: '',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          estimatedBytes: 1000,
        ),
        throwsA(isA<AssertionError>()),
      );

      expect(
        () => VGStreamingOfflineAssetAcquisitionRequest(
          requestId: 'valid_id',
          sourceKey: 'valid_key',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          estimatedBytes: 0,
        ),
        throwsA(isA<AssertionError>()),
      );

      expect(
        () => VGStreamingOfflineAssetAcquisitionRequest(
          requestId: 'valid_id',
          sourceKey: 'valid_key',
          uri: Uri.parse('https://example.com/stream.m3u8'),
          estimatedBytes: -100,
        ),
        throwsA(isA<AssertionError>()),
      );

      // VGStreamingOfflineAssetDroppedAcquisitionCandidate assertions
      expect(
        () => VGStreamingOfflineAssetDroppedAcquisitionCandidate(
          candidate: candidateHlsMain,
          reason: '',
        ),
        throwsA(isA<AssertionError>()),
      );

      // VGStreamingOfflineAssetAcquisitionPlanner.plan assertions
      final validEligibilityPlan = VGStreamingOfflineAssetEligibilityPlan(
        candidates: [candidateHlsMain],
      );

      expect(
        () => VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: validEligibilityPlan,
          requestIdPrefix: '',
        ),
        throwsA(isA<AssertionError>()),
      );

      expect(
        () => VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: validEligibilityPlan,
          requestIdPrefix: 'valid_prefix',
          defaultEstimatedBytes: 0,
        ),
        throwsA(isA<AssertionError>()),
      );

      expect(
        () => VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: validEligibilityPlan,
          requestIdPrefix: 'valid_prefix',
          defaultEstimatedBytes: -1,
        ),
        throwsA(isA<AssertionError>()),
      );

      expect(
        () => VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: validEligibilityPlan,
          requestIdPrefix: 'valid_prefix',
          maxTotalEstimatedBytesBudget: -1,
        ),
        throwsA(isA<AssertionError>()),
      );

      expect(
        () => VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: validEligibilityPlan,
          requestIdPrefix: 'valid_prefix',
          estimatedBytesBySourceKey: {'hls_main': 0},
        ),
        throwsA(isA<AssertionError>()),
      );

      expect(
        () => VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: validEligibilityPlan,
          requestIdPrefix: 'valid_prefix',
          estimatedBytesBySourceKey: {'hls_main': -500},
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('Plan collections are immutable', () {
      final eligibilityPlan = VGStreamingOfflineAssetEligibilityPlan(
        candidates: [candidateHlsMain],
      );

      final plan = VGStreamingOfflineAssetAcquisitionPlanner.plan(
        eligibilityPlan: eligibilityPlan,
        requestIdPrefix: 'immutable_test',
      );

      expect(
        () => plan.requests.add(
          VGStreamingOfflineAssetAcquisitionRequest(
            requestId: 'x',
            sourceKey: 'x',
            uri: Uri.parse('https://example.com/x.m3u8'),
            estimatedBytes: 100,
          ),
        ),
        throwsUnsupportedError,
      );

      expect(
        () => plan.droppedCandidates.add(
          VGStreamingOfflineAssetDroppedAcquisitionCandidate(
            candidate: candidateHlsMain,
            reason: 'drop',
          ),
        ),
        throwsUnsupportedError,
      );

      expect(() => plan.warnings.add('new_warning'), throwsUnsupportedError);
      expect(() => plan.diagnostics['key'] = 'val', throwsUnsupportedError);
    });

    test(
      'Integration: builds VGStreamingOfflineAssetEligibilityPlan from descriptors and converts to acquisition requests; DASH/LL-HLS rejections are excluded',
      () {
        final hlsDescriptor = VGStreamingSourceDescriptor(
          key: 'vod_hls',
          uri: Uri.parse('https://example.com/vod.m3u8'),
          initialWidth: 1920,
          initialHeight: 1080,
          formatHint: VGStreamingFormatHint.hls,
          httpHeaders: const {'X-Custom-Auth': 'secret'},
        );

        final llHlsDescriptor = VGStreamingSourceDescriptor(
          key: 'live_ll_hls',
          uri: Uri.parse('https://example.com/live.m3u8'),
          initialWidth: 1280,
          initialHeight: 720,
          formatHint: VGStreamingFormatHint.hls,
          requireLlHlsTags: true,
        );

        final dashDescriptor = VGStreamingSourceDescriptor(
          key: 'vod_dash',
          uri: Uri.parse('https://example.com/vod.mpd'),
          initialWidth: 1920,
          initialHeight: 1080,
          formatHint: VGStreamingFormatHint.dash,
        );

        final sourceSet = VGStreamingSourceSet(
          sources: [hlsDescriptor, llHlsDescriptor, dashDescriptor],
        );

        // 1. Evaluate eligibility with default constraints (LL-HLS constrained, DASH deferred).
        final eligibilityPlan = VGStreamingOfflineAssetEligibilityPlanner.plan(
          VGStreamingOfflineAssetEligibilityRequest(
            sourceSet: sourceSet,
            allowLowLatency: false,
            allowDash: false,
          ),
        );

        expect(eligibilityPlan.candidates, hasLength(1));
        expect(eligibilityPlan.candidates.single.sourceKey, equals('vod_hls'));
        expect(eligibilityPlan.rejectedSources, hasLength(2));

        // 2. Plan acquisition from eligibility plan.
        final acquisitionPlan = VGStreamingOfflineAssetAcquisitionPlanner.plan(
          eligibilityPlan: eligibilityPlan,
          requestIdPrefix: 'vod_offline_job',
          defaultEstimatedBytes: 80 * 1024 * 1024,
          prioritiesBySourceKey: {
            'vod_hls': VGStreamingOfflineAssetAcquisitionPriority.urgent,
          },
          reasonsBySourceKey: {'vod_hls': 'user_requested_download'},
        );

        expect(acquisitionPlan.hasRequests, isTrue);
        expect(acquisitionPlan.hasDrops, isFalse);
        expect(acquisitionPlan.requests, hasLength(1));

        final req = acquisitionPlan.requests.single;
        expect(req.requestId, equals('vod_offline_job_vod_hls_0'));
        expect(req.sourceKey, equals('vod_hls'));
        expect(req.uri, equals(hlsDescriptor.uri));
        expect(req.httpHeaders, equals({'X-Custom-Auth': 'secret'}));
        expect(req.estimatedBytes, equals(80 * 1024 * 1024));
        expect(
          req.priority,
          equals(VGStreamingOfflineAssetAcquisitionPriority.urgent),
        );
        expect(req.reason, equals('user_requested_download'));

        // Warnings from eligibility rejections are propagated.
        expect(
          acquisitionPlan.warnings,
          contains(
            'offline_rejected:live_ll_hls:low_latency_offline_constrained',
          ),
        );
        expect(
          acquisitionPlan.warnings,
          contains('offline_rejected:vod_dash:dash_offline_deferred'),
        );

        expect(
          acquisitionPlan.diagnostics['eligibilityRejectedCount'],
          equals(2),
        );
        expect(
          acquisitionPlan.diagnostics['eligibilityCandidateCount'],
          equals(1),
        );
      },
    );

    test('toString produces descriptive string', () {
      final req = VGStreamingOfflineAssetAcquisitionRequest(
        requestId: 'req_test',
        sourceKey: 'source_test',
        uri: Uri.parse('https://example.com/test.m3u8'),
        estimatedBytes: 1024,
        priority: VGStreamingOfflineAssetAcquisitionPriority.high,
        reason: 'test_reason',
      );
      expect(req.toString(), contains('requestId=req_test'));
      expect(req.toString(), contains('priority=high'));

      final drop = VGStreamingOfflineAssetDroppedAcquisitionCandidate(
        candidate: candidateHlsMain,
        reason: 'test_drop_reason',
      );
      expect(drop.toString(), contains('candidate=hls_main'));
      expect(drop.toString(), contains('reason=test_drop_reason'));

      final plan = VGStreamingOfflineAssetAcquisitionPlan(
        requests: [req],
        droppedCandidates: [drop],
      );
      expect(plan.toString(), contains('requests=1'));
      expect(plan.toString(), contains('droppedCandidates=1'));
      expect(plan.toString(), contains('totalEstimatedBytes=1024'));
    });
  });
}
