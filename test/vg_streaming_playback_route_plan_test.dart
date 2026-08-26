// Copyright (c) Connects — Vanguard Phase 4C7BD.
// Public streaming playback route planner unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackRoutePlanner', () {
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

    final hlsNoCacheSource = VGStreamingSourceDescriptor(
      key: 'hls_nocache',
      uri: Uri.parse('https://example.com/nocache.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
      cacheOptions: const VGPlaybackCacheOptions(cacheEnabled: false),
      autoPlay: true,
    );

    final hlsNullCacheSource = VGStreamingSourceDescriptor(
      key: 'hls_nullcache',
      uri: Uri.parse('https://example.com/nullcache.m3u8'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.hls,
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

    final customSource = VGStreamingSourceDescriptor(
      key: 'custom_format',
      uri: Uri.parse('https://example.com/stream.bin'),
      initialWidth: 1920,
      initialHeight: 1080,
      formatHint: VGStreamingFormatHint.auto,
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
      warnings: <String>['advisory_info'],
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

    VGStreamingPlaybackDecision makeDecisionForSource(
      VGStreamingSourceDescriptor source, {
      VGStreamingPreflightReport report = validReport,
      VGStreamingSourceClientCapabilities? capabilities,
    }) {
      return VGStreamingPlaybackDecisionPlanner.plan(
        VGStreamingPlaybackDecisionRequest(
          sourceSet: VGStreamingSourceSet(sources: [source]),
          preflightReport: report,
          clientCapabilities: capabilities,
        ),
      );
    }

    test(
      'online cache route selected when cacheEnabled is true on selected source',
      () {
        final decision = makeDecisionForSource(hlsCachedSource);
        expect(decision.canOpenPlayback, isTrue);

        final plan = VGStreamingPlaybackRoutePlanner.plan(
          VGStreamingPlaybackRouteRequest(decision: decision),
        );

        expect(plan.mode, equals(VGStreamingPlaybackRouteMode.onlineCache));
        expect(plan.shouldUseOnlineCache, isTrue);
        expect(plan.shouldUseNetwork, isFalse);
        expect(plan.shouldUseOfflineAsset, isFalse);
        expect(plan.canOpenWithCurrentPlaybackClient, isTrue);
        expect(plan.requiresOfflineAssetPlayback, isFalse);
        expect(plan.playbackOptions, isNotNull);
        expect(plan.playbackOptions?.cacheOptions?.cacheEnabled, isTrue);
        expect(plan.advisoryOnly, isTrue);
        expect(plan.playbackMutation, isFalse);
        expect(plan.decision, equals('online_cache_playback_ready'));
        expect(plan.selectedKey, equals('hls_cached'));
        expect(plan.diagnostics['cacheEnabled'], isTrue);
        expect(plan.diagnostics['selectedFormat'], equals('hls'));
      },
    );

    test(
      'network route selected when cacheEnabled is false or options are null',
      () {
        // Disabled cache
        final decisionNoCache = makeDecisionForSource(hlsNoCacheSource);
        final planNoCache = VGStreamingPlaybackRoutePlanner.plan(
          VGStreamingPlaybackRouteRequest(decision: decisionNoCache),
        );

        expect(planNoCache.mode, equals(VGStreamingPlaybackRouteMode.network));
        expect(planNoCache.shouldUseNetwork, isTrue);
        expect(planNoCache.shouldUseOnlineCache, isFalse);
        expect(planNoCache.canOpenWithCurrentPlaybackClient, isTrue);
        expect(planNoCache.requiresOfflineAssetPlayback, isFalse);
        expect(planNoCache.playbackOptions, isNotNull);
        expect(planNoCache.decision, equals('network_playback_ready'));
        expect(planNoCache.diagnostics['cacheEnabled'], isFalse);

        // Null cache options
        final decisionNullCache = makeDecisionForSource(hlsNullCacheSource);
        final planNullCache = VGStreamingPlaybackRoutePlanner.plan(
          VGStreamingPlaybackRouteRequest(decision: decisionNullCache),
        );

        expect(
          planNullCache.mode,
          equals(VGStreamingPlaybackRouteMode.network),
        );
        expect(planNullCache.shouldUseNetwork, isTrue);
        expect(planNullCache.canOpenWithCurrentPlaybackClient, isTrue);
        expect(planNullCache.decision, equals('network_playback_ready'));
        expect(planNullCache.diagnostics['cacheEnabled'], isFalse);
      },
    );

    test('offline HLS available routes to offlineAsset mode', () {
      final decision = makeDecisionForSource(hlsCachedSource);
      final assetUri = Uri.parse(
        'file:///var/mobile/Containers/Data/Application/offline.movpkg',
      );
      final availability = VGStreamingOfflineAssetAvailability(
        sourceKey: 'hls_cached',
        state: VGStreamingOfflineAssetState.available,
        assetUri: assetUri,
        downloadedBytes: 15728640,
        expiresAtUnixMs: 1800000000000,
        reason: 'fully_downloaded',
      );

      final plan = VGStreamingPlaybackRoutePlanner.plan(
        VGStreamingPlaybackRouteRequest(
          decision: decision,
          preferOffline: true,
          offlineAssetsBySourceKey: {'hls_cached': availability},
        ),
      );

      expect(plan.mode, equals(VGStreamingPlaybackRouteMode.offlineAsset));
      expect(plan.shouldUseOfflineAsset, isTrue);
      expect(plan.shouldUseOnlineCache, isFalse);
      expect(plan.shouldUseNetwork, isFalse);
      expect(plan.requiresOfflineAssetPlayback, isFalse);
      expect(plan.canOpenWithCurrentPlaybackClient, isTrue);
      expect(plan.playbackOptions, isNotNull);
      expect(plan.playbackOptions?.uri, equals(assetUri));
      expect(plan.playbackOptions?.cacheOptions, isNull);
      expect(plan.playbackOptions?.httpHeaders, isNull);
      expect(plan.playbackOptions?.initialWidth, equals(1920));
      expect(plan.playbackOptions?.initialHeight, equals(1080));
      expect(plan.playbackOptions?.autoPlay, isTrue);
      expect(
        plan.playbackOptions?.formatHint,
        equals(VGStreamingFormatHint.hls),
      );
      expect(plan.decision, equals('offline_asset_ready'));
      expect(plan.offlineAsset, isNotNull);
      expect(plan.offlineAsset?.isPlayableOffline, isTrue);
      expect(plan.offlineAsset?.sourceKey, equals('hls_cached'));
      expect(plan.diagnostics['offlineAssetState'], equals('available'));
      expect(plan.diagnostics['hasOfflineAssetUri'], isTrue);
      expect(plan.diagnostics['offlineAssetUriScheme'], equals('file'));
      expect(plan.diagnostics['canOpenWithCurrentPlaybackClient'], isTrue);
      expect(plan.diagnostics['requiresOfflineAssetPlayback'], isFalse);
      expect(plan.diagnostics['downloadedBytes'], equals(15728640));

      final json = availability.toJson();
      expect(json['sourceKey'], equals('hls_cached'));
      expect(json['state'], equals('available'));
      expect(json['assetUri'], equals(assetUri.toString()));
      expect(json['downloadedBytes'], equals(15728640));
      expect(json['expiresAtUnixMs'], equals(1800000000000));
      expect(json['reason'], equals('fully_downloaded'));
      expect(json['isPlayableOffline'], isTrue);
    });

    test(
      'offline HLS playback options strip headers and cacheOptions while preserving dimensions and timing',
      () {
        final sourceWithHeadersAndCache = VGStreamingSourceDescriptor(
          key: 'hls_custom',
          uri: Uri.parse('https://example.com/custom.m3u8'),
          initialWidth: 1280,
          initialHeight: 720,
          formatHint: VGStreamingFormatHint.hls,
          autoPlay: false,
          initialPositionMs: 12345,
          httpHeaders: const {'Authorization': 'Bearer test-token'},
          cacheOptions: const VGPlaybackCacheOptions(
            cacheEnabled: true,
            cacheMaxBytes: 100 * 1024 * 1024,
          ),
        );
        final decision = makeDecisionForSource(sourceWithHeadersAndCache);
        final assetUri = Uri.parse('file:///data/local/offline.movpkg');
        final availability = VGStreamingOfflineAssetAvailability(
          sourceKey: 'hls_custom',
          state: VGStreamingOfflineAssetState.available,
          assetUri: assetUri,
        );

        final plan = VGStreamingPlaybackRoutePlanner.plan(
          VGStreamingPlaybackRouteRequest(
            decision: decision,
            preferOffline: true,
            offlineAssetsBySourceKey: {'hls_custom': availability},
          ),
        );

        expect(plan.mode, equals(VGStreamingPlaybackRouteMode.offlineAsset));
        expect(plan.playbackOptions, isNotNull);
        final opts = plan.playbackOptions!;
        expect(opts.uri, equals(assetUri));
        expect(opts.httpHeaders, isNull);
        expect(opts.cacheOptions, isNull);
        expect(opts.initialWidth, equals(1280));
        expect(opts.initialHeight, equals(720));
        expect(opts.autoPlay, isFalse);
        expect(opts.initialPositionMs, equals(12345));
        expect(opts.networkProfile, equals(VGStreamingNetworkProfile.stable));
        expect(opts.formatHint, equals(VGStreamingFormatHint.hls));
      },
    );

    test(
      'offline unavailable with allowNetworkFallback falls through to online cache or network',
      () {
        final decision = makeDecisionForSource(hlsCachedSource);

        // Missing availability record
        final planMissing = VGStreamingPlaybackRoutePlanner.plan(
          VGStreamingPlaybackRouteRequest(
            decision: decision,
            preferOffline: true,
            allowNetworkFallback: true,
          ),
        );

        expect(
          planMissing.mode,
          equals(VGStreamingPlaybackRouteMode.onlineCache),
        );
        expect(planMissing.canOpenWithCurrentPlaybackClient, isTrue);
        expect(planMissing.requiresOfflineAssetPlayback, isFalse);
        expect(
          planMissing.warnings,
          contains('offline_asset_missing:hls_cached'),
        );
        expect(
          planMissing.warnings,
          contains('offline_fallback_to_network:hls_cached'),
        );

        // Unavailable state record
        final unavailableAsset = const VGStreamingOfflineAssetAvailability(
          sourceKey: 'hls_cached',
          state: VGStreamingOfflineAssetState.unavailable,
          reason: 'not_downloaded',
        );
        final planUnavailable = VGStreamingPlaybackRoutePlanner.plan(
          VGStreamingPlaybackRouteRequest(
            decision: decision,
            preferOffline: true,
            allowNetworkFallback: true,
            offlineAssetsBySourceKey: {'hls_cached': unavailableAsset},
          ),
        );

        expect(
          planUnavailable.mode,
          equals(VGStreamingPlaybackRouteMode.onlineCache),
        );
        expect(
          planUnavailable.warnings,
          contains('offline_asset_not_playable:hls_cached:unavailable'),
        );
        expect(
          planUnavailable.warnings,
          contains('offline_fallback_to_network:hls_cached'),
        );
      },
    );

    test('offline unavailable without network fallback returns blocked', () {
      final decision = makeDecisionForSource(hlsCachedSource);

      // Missing availability record with fallback disabled
      final planMissing = VGStreamingPlaybackRoutePlanner.plan(
        VGStreamingPlaybackRouteRequest(
          decision: decision,
          preferOffline: true,
          allowNetworkFallback: false,
        ),
      );

      expect(planMissing.mode, equals(VGStreamingPlaybackRouteMode.blocked));
      expect(planMissing.decision, equals('offline_route_blocked'));
      expect(planMissing.playbackOptions, isNull);
      expect(planMissing.canOpenWithCurrentPlaybackClient, isFalse);
      expect(planMissing.requiresOfflineAssetPlayback, isFalse);
      expect(
        planMissing.warnings,
        contains('offline_asset_missing:hls_cached'),
      );

      // Expired state with fallback disabled
      final expiredAsset = VGStreamingOfflineAssetAvailability(
        sourceKey: 'hls_cached',
        state: VGStreamingOfflineAssetState.expired,
        assetUri: Uri.parse('file:///offline.movpkg'),
        reason: 'license_expired',
      );
      final planExpired = VGStreamingPlaybackRoutePlanner.plan(
        VGStreamingPlaybackRouteRequest(
          decision: decision,
          preferOffline: true,
          allowNetworkFallback: false,
          offlineAssetsBySourceKey: {'hls_cached': expiredAsset},
        ),
      );

      expect(planExpired.mode, equals(VGStreamingPlaybackRouteMode.blocked));
      expect(planExpired.decision, equals('offline_route_blocked'));
      expect(
        planExpired.warnings,
        contains('offline_asset_not_playable:hls_cached:expired'),
      );
      expect(planExpired.diagnostics['allowNetworkFallback'], isFalse);
    });

    test(
      'LL-HLS offline preferred emits low latency warning and falls back or blocks',
      () {
        final decision = makeDecisionForSource(llHlsSource);
        expect(decision.canOpenPlayback, isTrue);

        // With network fallback
        final planFallback = VGStreamingPlaybackRoutePlanner.plan(
          VGStreamingPlaybackRouteRequest(
            decision: decision,
            preferOffline: true,
            allowNetworkFallback: true,
          ),
        );

        expect(planFallback.mode, equals(VGStreamingPlaybackRouteMode.network));
        expect(
          planFallback.warnings,
          contains('offline_low_latency_not_supported:ll_hls_main'),
        );
        expect(
          planFallback.warnings,
          contains('offline_fallback_to_network:ll_hls_main'),
        );

        // Without network fallback
        final planBlocked = VGStreamingPlaybackRoutePlanner.plan(
          VGStreamingPlaybackRouteRequest(
            decision: decision,
            preferOffline: true,
            allowNetworkFallback: false,
          ),
        );

        expect(planBlocked.mode, equals(VGStreamingPlaybackRouteMode.blocked));
        expect(planBlocked.decision, equals('offline_route_blocked'));
        expect(
          planBlocked.warnings,
          contains('offline_low_latency_not_supported:ll_hls_main'),
        );
      },
    );

    test('DASH offline preferred emits warning and handles fallback/block', () {
      final decision = makeDecisionForSource(dashSource);
      expect(decision.canOpenPlayback, isTrue);

      // Without fallback -> blocked
      final planBlocked = VGStreamingPlaybackRoutePlanner.plan(
        VGStreamingPlaybackRouteRequest(
          decision: decision,
          preferOffline: true,
          allowNetworkFallback: false,
        ),
      );

      expect(planBlocked.mode, equals(VGStreamingPlaybackRouteMode.blocked));
      expect(planBlocked.decision, equals('offline_route_blocked'));
      expect(
        planBlocked.warnings,
        contains('offline_dash_not_supported:dash_main'),
      );

      // With fallback -> network
      final planFallback = VGStreamingPlaybackRoutePlanner.plan(
        VGStreamingPlaybackRouteRequest(
          decision: decision,
          preferOffline: true,
          allowNetworkFallback: true,
        ),
      );

      expect(planFallback.mode, equals(VGStreamingPlaybackRouteMode.network));
      expect(
        planFallback.warnings,
        contains('offline_dash_not_supported:dash_main'),
      );
      expect(
        planFallback.warnings,
        contains('offline_fallback_to_network:dash_main'),
      );
    });

    test(
      'custom unsupported format emits offline_format_not_supported warning',
      () {
        final decision = makeDecisionForSource(customSource);
        expect(decision.canOpenPlayback, isTrue);

        final plan = VGStreamingPlaybackRoutePlanner.plan(
          VGStreamingPlaybackRouteRequest(
            decision: decision,
            preferOffline: true,
            allowNetworkFallback: false,
          ),
        );

        expect(plan.mode, equals(VGStreamingPlaybackRouteMode.blocked));
        expect(plan.decision, equals('offline_route_blocked'));
        expect(
          plan.warnings,
          contains('offline_format_not_supported:custom_format'),
        );
      },
    );

    test(
      'upstream blocked decision remains blocked and preserves warnings',
      () {
        final blockedDecision = makeDecisionForSource(
          hlsCachedSource,
          report: blockedReport,
        );
        expect(blockedDecision.canOpenPlayback, isFalse);

        final plan = VGStreamingPlaybackRoutePlanner.plan(
          VGStreamingPlaybackRouteRequest(
            decision: blockedDecision,
            preferOffline: true,
          ),
        );

        expect(plan.mode, equals(VGStreamingPlaybackRouteMode.blocked));
        expect(
          plan.decision,
          equals('playback_decision_blocked:startup_plan_blocked'),
        );
        expect(plan.canOpenWithCurrentPlaybackClient, isFalse);
        expect(plan.requiresOfflineAssetPlayback, isFalse);
        expect(plan.playbackOptions, isNull);
        expect(plan.warnings, contains('network_unreachable'));
        expect(plan.diagnostics['canOpenPlayback'], isFalse);
        expect(
          plan.diagnostics['originalDecision'],
          equals('startup_plan_blocked'),
        );
      },
    );

    test(
      'VGStreamingOfflineAssetAvailability constructor asserts and getters',
      () {
        // Empty sourceKey
        expect(
          () => VGStreamingOfflineAssetAvailability(sourceKey: ''),
          throwsA(isA<AssertionError>()),
        );

        // Negative downloadedBytes
        expect(
          () => VGStreamingOfflineAssetAvailability(
            sourceKey: 'test',
            downloadedBytes: -1,
          ),
          throwsA(isA<AssertionError>()),
        );

        // Negative expiresAtUnixMs
        expect(
          () => VGStreamingOfflineAssetAvailability(
            sourceKey: 'test',
            expiresAtUnixMs: -1,
          ),
          throwsA(isA<AssertionError>()),
        );

        // Available state without URI is not playable
        const noUriAsset = VGStreamingOfflineAssetAvailability(
          sourceKey: 'test',
          state: VGStreamingOfflineAssetState.available,
        );
        expect(noUriAsset.isPlayableOffline, isFalse);

        // Available state with URI is playable
        final uriAsset = VGStreamingOfflineAssetAvailability(
          sourceKey: 'test',
          state: VGStreamingOfflineAssetState.available,
          assetUri: Uri.parse('file:///asset.movpkg'),
        );
        expect(uriAsset.isPlayableOffline, isTrue);

        expect(uriAsset.toString(), contains('sourceKey=test'));
      },
    );

    test('VGStreamingPlaybackRouteRequest defaults and immutability', () {
      final decision = makeDecisionForSource(hlsCachedSource);
      final req = VGStreamingPlaybackRouteRequest(decision: decision);

      expect(req.preferOffline, isFalse);
      expect(req.allowNetworkFallback, isTrue);
      expect(req.offlineAssetsBySourceKey, isEmpty);
      expect(req.toString(), contains('preferOffline=false'));
    });

    test('VGStreamingPlaybackRoutePlan immutability and toString', () {
      final plan = VGStreamingPlaybackRoutePlan(
        mode: VGStreamingPlaybackRouteMode.network,
        decision: 'test_ready',
        canOpenWithCurrentPlaybackClient: true,
        requiresOfflineAssetPlayback: false,
        warnings: ['w1', 'w2'],
        diagnostics: {'k': 'v'},
      );

      expect(() => plan.warnings.add('w3'), throwsUnsupportedError);
      expect(() => plan.diagnostics['k2'] = 'v2', throwsUnsupportedError);
      expect(plan.toString(), contains('mode=network'));
    });
  });
}
