// Copyright (c) Connects — Vanguard Phase 4C7BG.
// Public streaming offline playback preparation planner unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingOfflinePlaybackPreparationPlanner', () {
    final hlsCachedSource = VGStreamingSourceDescriptor(
      key: 'hls_cached',
      uri: Uri.parse('https://example.com/cached.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
      cacheOptions: const VGPlaybackCacheOptions(
        cacheEnabled: true,
        cacheMaxBytes: 50 * 1024 * 1024,
      ),
      autoPlay: true,
    );

    final hlsNetworkSource = VGStreamingSourceDescriptor(
      key: 'hls_network',
      uri: Uri.parse('https://example.com/network.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
      cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: false),
      autoPlay: true,
    );

    final dashSource = VGStreamingSourceDescriptor(
      key: 'dash_main',
      uri: Uri.parse('https://example.com/main.mpd'),
      initialWidth: 1280,
      initialHeight: 720,
      formatHint: VGStreamingFormatHint.dash,
      autoPlay: false,
    );

    final llHlsSource = VGStreamingSourceDescriptor(
      key: 'll_hls_main',
      uri: Uri.parse('https://example.com/ll_stream.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
      requireLlHlsTags: true,
      autoPlay: true,
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
      warnings: <String>['advisory_preflight_info'],
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

    VGStreamingPlaybackDecision makeDecision(
      List<VGStreamingSourceDescriptor> sources, {
      VGStreamingPreflightReport report = validReport,
      VGStreamingSourceClientCapabilities? capabilities,
    }) {
      return VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: VGStreamingSourceSet(sources: sources),
          preflightReport: report,
          clientCapabilities: capabilities,
        ),
      );
    }

    test(
      'Existing available offline HLS asset => openOfflineAsset action with canOpenNow true',
      () {
        final sourceSet = VGStreamingSourceSet(sources: [hlsCachedSource]);
        final decision = makeDecision([hlsCachedSource]);
        final offlineAsset = VGStreamingOfflineAssetAvailability(
          sourceKey: 'hls_cached',
          state: VGStreamingOfflineAssetState.available,
          assetUri: Uri.parse('file:///var/mobile/offline.movpkg'),
          downloadedBytes: 20 * 1024 * 1024,
          reason: 'download_complete',
        );

        final plan = VGStreamingOfflinePlaybackPreparationPlanner.plan(
          VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            preferOffline: true,
            offlineAssetsBySourceKey: {'hls_cached': offlineAsset},
          ),
        );

        expect(
          plan.action,
          equals(VGStreamingOfflinePlaybackPreparationAction.openOfflineAsset),
        );
        expect(
          plan.routePlan.mode,
          equals(VGStreamingPlaybackRouteMode.offlineAsset),
        );
        expect(plan.canOpenNow, isTrue);
        expect(plan.isBlocked, isFalse);
        expect(plan.requiresOfflineAssetPlayback, isFalse);
        expect(plan.canOpenWithCurrentPlaybackClient, isTrue);
        expect(plan.shouldAcquireOfflineAsset, isFalse);
        expect(plan.selectedKey, equals('hls_cached'));
        expect(plan.diagnostics['action'], equals('openOfflineAsset'));
        expect(plan.diagnostics['routeMode'], equals('offlineAsset'));
        expect(plan.diagnostics['requiresOfflineAssetPlayback'], isFalse);
        expect(plan.diagnostics['canOpenWithCurrentPlaybackClient'], isTrue);
      },
    );

    test(
      'Offline preferred but asset missing and network fallback allowed => acquireOfflineAsset with recommended warning and online route',
      () {
        final sourceSet = VGStreamingSourceSet(sources: [hlsCachedSource]);
        final decision = makeDecision([hlsCachedSource]);

        final plan = VGStreamingOfflinePlaybackPreparationPlanner.plan(
          VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            preferOffline: true,
            allowNetworkFallback: true,
          ),
        );

        expect(
          plan.action,
          equals(
            VGStreamingOfflinePlaybackPreparationAction.acquireOfflineAsset,
          ),
        );
        expect(
          plan.routePlan.mode,
          equals(VGStreamingPlaybackRouteMode.onlineCache),
        );
        expect(plan.shouldAcquireOfflineAsset, isTrue);
        expect(plan.canOpenNow, isFalse);
        expect(plan.isBlocked, isFalse);
        expect(plan.acquisitionPlan.hasRequests, isTrue);
        expect(
          plan.warnings,
          contains('offline_acquisition_recommended:hls_cached'),
        );
        expect(
          plan.warnings,
          contains('offline_fallback_to_network:hls_cached'),
        );
      },
    );

    test(
      'Offline preferred, asset missing, no network fallback, selected HLS eligible => acquireOfflineAsset with required warning and blocked route',
      () {
        final sourceSet = VGStreamingSourceSet(sources: [hlsNetworkSource]);
        final decision = makeDecision([hlsNetworkSource]);

        final plan = VGStreamingOfflinePlaybackPreparationPlanner.plan(
          VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            preferOffline: true,
            allowNetworkFallback: false,
          ),
        );

        expect(
          plan.action,
          equals(
            VGStreamingOfflinePlaybackPreparationAction.acquireOfflineAsset,
          ),
        );
        expect(
          plan.routePlan.mode,
          equals(VGStreamingPlaybackRouteMode.blocked),
        );
        expect(plan.shouldAcquireOfflineAsset, isTrue);
        expect(plan.canOpenNow, isFalse);
        expect(plan.isBlocked, isFalse);
        expect(plan.acquisitionPlan.hasRequests, isTrue);
        expect(
          plan.warnings,
          contains('offline_acquisition_required:hls_network'),
        );
      },
    );

    test(
      'No offline preference => openOnlinePlayback with canOpenNow true and no acquisition warning',
      () {
        final sourceSet = VGStreamingSourceSet(sources: [hlsCachedSource]);
        final decision = makeDecision([hlsCachedSource]);

        final plan = VGStreamingOfflinePlaybackPreparationPlanner.plan(
          VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            preferOffline: false,
          ),
        );

        expect(
          plan.action,
          equals(
            VGStreamingOfflinePlaybackPreparationAction.openOnlinePlayback,
          ),
        );
        expect(
          plan.routePlan.mode,
          equals(VGStreamingPlaybackRouteMode.onlineCache),
        );
        expect(plan.canOpenNow, isTrue);
        expect(plan.isBlocked, isFalse);
        expect(plan.shouldAcquireOfflineAsset, isFalse);
        expect(
          plan.warnings.any(
            (w) =>
                w.startsWith('offline_acquisition_recommended') ||
                w.startsWith('offline_acquisition_required'),
          ),
          isFalse,
        );
      },
    );

    test(
      'DASH selected on Apple with preferOffline and no network fallback => blocked action and no acquisition requests',
      () {
        final sourceSet = VGStreamingSourceSet(sources: [dashSource]);
        final decision = makeDecision([
          dashSource,
        ], capabilities: VGStreamingSourceClientCapabilities.appleAvPlayer());

        final plan = VGStreamingOfflinePlaybackPreparationPlanner.plan(
          VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            preferOffline: true,
            allowNetworkFallback: false,
            clientCapabilities:
                VGStreamingSourceClientCapabilities.appleAvPlayer(),
            allowDashOffline: false,
          ),
        );

        expect(
          plan.action,
          equals(VGStreamingOfflinePlaybackPreparationAction.blocked),
        );
        expect(
          plan.routePlan.mode,
          equals(VGStreamingPlaybackRouteMode.blocked),
        );
        expect(plan.isBlocked, isTrue);
        expect(plan.canOpenNow, isFalse);
        expect(plan.shouldAcquireOfflineAsset, isFalse);
        expect(plan.acquisitionPlan.hasRequests, isFalse);
        expect(plan.eligibilityPlan.hasCandidates, isFalse);
        expect(plan.eligibilityPlan.hasRejections, isTrue);
        expect(
          plan.warnings,
          contains('offline_rejected:dash_main:dash_offline_deferred'),
        );
      },
    );

    test(
      'LL-HLS selected with default low-latency constraints => rejected from acquisition, falls back online or blocks',
      () {
        final sourceSet = VGStreamingSourceSet(sources: [llHlsSource]);
        final decision = makeDecision([llHlsSource]);

        // 1. With fallback allowed => online playback
        final planFallback = VGStreamingOfflinePlaybackPreparationPlanner.plan(
          VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            preferOffline: true,
            allowNetworkFallback: true,
            allowLowLatencyOffline: false,
          ),
        );

        expect(
          planFallback.action,
          equals(
            VGStreamingOfflinePlaybackPreparationAction.openOnlinePlayback,
          ),
        );
        expect(
          planFallback.routePlan.mode,
          equals(VGStreamingPlaybackRouteMode.network),
        );
        expect(planFallback.canOpenNow, isTrue);
        expect(planFallback.acquisitionPlan.hasRequests, isFalse);
        expect(
          planFallback.warnings,
          contains(
            'offline_rejected:ll_hls_main:low_latency_offline_constrained',
          ),
        );

        // 2. Without fallback allowed => blocked
        final planBlocked = VGStreamingOfflinePlaybackPreparationPlanner.plan(
          VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            preferOffline: true,
            allowNetworkFallback: false,
            allowLowLatencyOffline: false,
          ),
        );

        expect(
          planBlocked.action,
          equals(VGStreamingOfflinePlaybackPreparationAction.blocked),
        );
        expect(
          planBlocked.routePlan.mode,
          equals(VGStreamingPlaybackRouteMode.blocked),
        );
        expect(planBlocked.isBlocked, isTrue);
        expect(planBlocked.canOpenNow, isFalse);
      },
    );

    test(
      'Acquisition budget drop makes action blocked when route is blocked and all candidates dropped',
      () {
        final sourceSet = VGStreamingSourceSet(sources: [hlsNetworkSource]);
        final decision = makeDecision([hlsNetworkSource]);

        final plan = VGStreamingOfflinePlaybackPreparationPlanner.plan(
          VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            preferOffline: true,
            allowNetworkFallback: false,
            maxTotalEstimatedBytesBudget:
                0, // Budget is 0, drops all candidates
          ),
        );

        expect(
          plan.action,
          equals(VGStreamingOfflinePlaybackPreparationAction.blocked),
        );
        expect(
          plan.routePlan.mode,
          equals(VGStreamingPlaybackRouteMode.blocked),
        );
        expect(plan.isBlocked, isTrue);
        expect(plan.canOpenNow, isFalse);
        expect(plan.shouldAcquireOfflineAsset, isFalse);
        expect(plan.acquisitionPlan.hasRequests, isFalse);
        expect(plan.acquisitionPlan.hasDrops, isTrue);
        expect(
          plan.warnings,
          contains(
            'offline_acquisition_dropped:hls_network:estimated_budget_exceeded',
          ),
        );
      },
    );

    test(
      'Upstream playback decision blocked with HLS source still produces acquisition request/action acquireOfflineAsset when selectedKey/source is present and eligible',
      () {
        final sourceSet = VGStreamingSourceSet(sources: [hlsCachedSource]);
        final blockedDecision = VGStreamingPlaybackDecisionPlanner.plan(
          VGStreamingPlaybackDecisionRequest(
            sourceSet: sourceSet,
            preflightReport: blockedReport,
            requirePlanToProceed: false,
          ),
        );
        expect(blockedDecision.canOpenPlayback, isFalse);
        expect(blockedDecision.selectedKey, equals('hls_cached'));

        final plan = VGStreamingOfflinePlaybackPreparationPlanner.plan(
          VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: blockedDecision,
            sourceSet: sourceSet,
            preferOffline: true,
          ),
        );

        expect(
          plan.action,
          equals(
            VGStreamingOfflinePlaybackPreparationAction.acquireOfflineAsset,
          ),
        );
        expect(
          plan.routePlan.mode,
          equals(VGStreamingPlaybackRouteMode.blocked),
        );
        expect(plan.shouldAcquireOfflineAsset, isTrue);
        expect(plan.canOpenNow, isFalse);
        expect(plan.acquisitionPlan.hasRequests, isTrue);
        expect(
          plan.warnings,
          contains('offline_acquisition_required:hls_cached'),
        );
        expect(plan.warnings, contains('network_unreachable'));
      },
    );

    test('Warnings are deduped and diagnostics include expected counts', () {
      final sourceSet = VGStreamingSourceSet(sources: [hlsCachedSource]);
      final decision = makeDecision([hlsCachedSource]);

      final plan = VGStreamingOfflinePlaybackPreparationPlanner.plan(
        VGStreamingOfflinePlaybackPreparationRequest(
          playbackDecision: decision,
          sourceSet: sourceSet,
          preferOffline: true,
          allowNetworkFallback: true,
          acquisitionRequestIdPrefix: 'custom_job',
          defaultEstimatedBytes: 32 * 1024 * 1024,
          acquisitionPrioritiesBySourceKey: {
            'hls_cached': VGStreamingOfflineAssetAcquisitionPriority.urgent,
          },
          acquisitionReasonsBySourceKey: {
            'hls_cached': 'user_explicit_download',
          },
        ),
      );

      // Verify no duplicate warnings
      final uniqueWarnings = plan.warnings.toSet();
      expect(plan.warnings.length, equals(uniqueWarnings.length));

      // Verify diagnostics map
      expect(plan.diagnostics['action'], equals('acquireOfflineAsset'));
      expect(plan.diagnostics['routeMode'], equals('onlineCache'));
      expect(
        plan.diagnostics['routeDecision'],
        equals('online_cache_playback_ready'),
      );
      expect(plan.diagnostics['selectedKey'], equals('hls_cached'));
      expect(plan.diagnostics['eligibilityCandidateCount'], equals(1));
      expect(plan.diagnostics['eligibilityRejectedCount'], equals(0));
      expect(plan.diagnostics['acquisitionRequestCount'], equals(1));
      expect(plan.diagnostics['acquisitionDroppedCount'], equals(0));
      expect(plan.diagnostics['canOpenWithCurrentPlaybackClient'], isTrue);
      expect(plan.diagnostics['requiresOfflineAssetPlayback'], isFalse);
      expect(plan.diagnostics['shouldAcquireOfflineAsset'], isTrue);
      expect(plan.diagnostics['preferOffline'], isTrue);
      expect(plan.diagnostics['allowNetworkFallback'], isTrue);
      expect(plan.diagnostics['advisoryOnly'], isTrue);
      expect(plan.diagnostics['playbackMutation'], isFalse);
    });

    test(
      'Request assertions, map immutability, and plan immutability / toString',
      () {
        final sourceSet = VGStreamingSourceSet(sources: [hlsCachedSource]);
        final decision = makeDecision([hlsCachedSource]);

        // Assertion: empty acquisitionRequestIdPrefix
        expect(
          () => VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            acquisitionRequestIdPrefix: '',
          ),
          throwsA(isA<AssertionError>()),
        );

        // Assertion: defaultEstimatedBytes <= 0
        expect(
          () => VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            defaultEstimatedBytes: 0,
          ),
          throwsA(isA<AssertionError>()),
        );

        expect(
          () => VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            defaultEstimatedBytes: -10,
          ),
          throwsA(isA<AssertionError>()),
        );

        // Assertion: maxTotalEstimatedBytesBudget < 0
        expect(
          () => VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            maxTotalEstimatedBytesBudget: -1,
          ),
          throwsA(isA<AssertionError>()),
        );

        // Assertion: non-positive values in acquisitionEstimatedBytesBySourceKey
        expect(
          () => VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            acquisitionEstimatedBytesBySourceKey: {'hls_cached': 0},
          ),
          throwsA(isA<AssertionError>()),
        );

        expect(
          () => VGStreamingOfflinePlaybackPreparationRequest(
            playbackDecision: decision,
            sourceSet: sourceSet,
            acquisitionEstimatedBytesBySourceKey: {'hls_cached': -100},
          ),
          throwsA(isA<AssertionError>()),
        );

        // Request map immutability
        final req = VGStreamingOfflinePlaybackPreparationRequest(
          playbackDecision: decision,
          sourceSet: sourceSet,
          offlineAssetsBySourceKey: {
            'hls_cached': const VGStreamingOfflineAssetAvailability(
              sourceKey: 'hls_cached',
            ),
          },
          acquisitionPrioritiesBySourceKey: {
            'hls_cached': VGStreamingOfflineAssetAcquisitionPriority.high,
          },
          acquisitionEstimatedBytesBySourceKey: {'hls_cached': 1000},
          acquisitionReasonsBySourceKey: {'hls_cached': 'reason'},
        );

        expect(
          () => req.offlineAssetsBySourceKey['new'] =
              const VGStreamingOfflineAssetAvailability(sourceKey: 'new'),
          throwsUnsupportedError,
        );
        expect(
          () => req.acquisitionPrioritiesBySourceKey['new'] =
              VGStreamingOfflineAssetAcquisitionPriority.low,
          throwsUnsupportedError,
        );
        expect(
          () => req.acquisitionEstimatedBytesBySourceKey['new'] = 100,
          throwsUnsupportedError,
        );
        expect(
          () => req.acquisitionReasonsBySourceKey['new'] = 'x',
          throwsUnsupportedError,
        );

        expect(req.toString(), contains('playbackDecision=playback_ready'));
        expect(req.toString(), contains('defaultEstimatedBytes=67108864'));

        // Plan immutability and toString
        final plan = VGStreamingOfflinePlaybackPreparationPlanner.plan(req);
        expect(() => plan.warnings.add('new_warning'), throwsUnsupportedError);
        expect(
          () => plan.diagnostics['new_diag'] = 'val',
          throwsUnsupportedError,
        );
        expect(plan.toString(), contains('action=openOnlinePlayback'));
      },
    );
  });
}
