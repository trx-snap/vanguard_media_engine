// Copyright (c) Connects — Vanguard Phase 4C7E.
// Public streaming preflight advisory API Dart contract tests.

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

  // ─────────────────────────────────────────────────────────────────────────
  // 1. VGStreamingManifestSpec
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingManifestSpec', () {
    test('enforces non-empty key assertion', () {
      expect(
        () => VGStreamingManifestSpec(
          key: '',
          uri: Uri.parse('https://example.com/master.m3u8'),
        ),
        throwsAssertionError,
      );
    });

    test('toArgs outputs defaults correctly', () {
      final spec = VGStreamingManifestSpec(
        key: 'default_spec',
        uri: Uri.parse('https://example.com/master.m3u8'),
      );

      final args = spec.toArgs();
      expect(args['key'], equals('default_spec'));
      expect(args['uri'], equals('https://example.com/master.m3u8'));
      expect(args['formatHint'], equals('AUTO'));
      expect(args['requireAdaptiveLadder'], isTrue);
      expect(args['requireAvcFallback'], isTrue);
      expect(args['requireLlHlsTags'], isFalse);
      expect(args['allowMediaPlaylist'], isFalse);
      expect(args.containsKey('httpHeaders'), isFalse);
    });

    test('toArgs serializes HLS spec with custom options and headers', () {
      final spec = VGStreamingManifestSpec(
        key: 'hls_custom_spec',
        uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        formatHint: VGStreamingFormatHint.hls,
        requireAdaptiveLadder: true,
        requireAvcFallback: true,
        requireLlHlsTags: true,
        allowMediaPlaylist: true,
        httpHeaders: const {
          'Authorization': 'Bearer token_123',
          'X-Custom-Header': 'CustomValue',
        },
      );

      final args = spec.toArgs();
      expect(args['key'], equals('hls_custom_spec'));
      expect(
        args['uri'],
        equals('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
      );
      expect(args['formatHint'], equals('HLS'));
      expect(args['requireAdaptiveLadder'], isTrue);
      expect(args['requireAvcFallback'], isTrue);
      expect(args['requireLlHlsTags'], isTrue);
      expect(args['allowMediaPlaylist'], isTrue);
      expect(
        args['httpHeaders'],
        equals({
          'Authorization': 'Bearer token_123',
          'X-Custom-Header': 'CustomValue',
        }),
      );
    });

    test('toArgs serializes DASH spec correctly', () {
      final spec = VGStreamingManifestSpec(
        key: 'dash_spec',
        uri: Uri.parse(
          'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
        ),
        formatHint: VGStreamingFormatHint.dash,
        requireAdaptiveLadder: false,
        requireAvcFallback: false,
        requireLlHlsTags: false,
        allowMediaPlaylist: false,
      );

      final args = spec.toArgs();
      expect(args['key'], equals('dash_spec'));
      expect(
        args['uri'],
        equals(
          'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
        ),
      );
      expect(args['formatHint'], equals('DASH'));
      expect(args['requireAdaptiveLadder'], isFalse);
      expect(args['requireAvcFallback'], isFalse);
      expect(args['requireLlHlsTags'], isFalse);
      expect(args['allowMediaPlaylist'], isFalse);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGStreamingPreflightRequest
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingPreflightRequest', () {
    test('enforces non-empty manifests assertion', () {
      expect(
        () => VGStreamingPreflightRequest(
          manifests: const <VGStreamingManifestSpec>[],
        ),
        throwsAssertionError,
      );
    });

    test('toArgs outputs defaults correctly', () {
      final request = VGStreamingPreflightRequest(
        manifests: [
          VGStreamingManifestSpec(
            key: 'spec_1',
            uri: Uri.parse('https://example.com/hls.m3u8'),
          ),
        ],
      );

      final args = request.toArgs();
      expect(args['manifests'], isA<List>());
      final manifestsList = args['manifests'] as List;
      expect(manifestsList.length, equals(1));
      expect(manifestsList.first['key'], equals('spec_1'));
      expect(args['requestedNetworkProfile'], equals('AUTO'));
      expect(args['preferLowLatency'], isFalse);
      expect(args['allowLowLatencyOnConstrained'], isFalse);
    });

    test('toArgs serializes all network profile enums accurately', () {
      final spec = VGStreamingManifestSpec(
        key: 'spec_test',
        uri: Uri.parse('https://example.com/test.m3u8'),
      );

      final reqAuto = VGStreamingPreflightRequest(
        manifests: [spec],
        requestedNetworkProfile: VGStreamingNetworkProfile.auto,
      );
      expect(reqAuto.toArgs()['requestedNetworkProfile'], equals('AUTO'));

      final reqStable = VGStreamingPreflightRequest(
        manifests: [spec],
        requestedNetworkProfile: VGStreamingNetworkProfile.stable,
      );
      expect(reqStable.toArgs()['requestedNetworkProfile'], equals('STABLE'));

      final reqConstrained = VGStreamingPreflightRequest(
        manifests: [spec],
        requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
      );
      expect(
        reqConstrained.toArgs()['requestedNetworkProfile'],
        equals('CONSTRAINED'),
      );

      final reqLowLatency = VGStreamingPreflightRequest(
        manifests: [spec],
        requestedNetworkProfile: VGStreamingNetworkProfile.lowLatency,
      );
      expect(
        reqLowLatency.toArgs()['requestedNetworkProfile'],
        equals('LOW_LATENCY'),
      );
    });

    test('toArgs serializes multiple manifests and boolean flags', () {
      final request = VGStreamingPreflightRequest(
        manifests: [
          VGStreamingManifestSpec(
            key: 'mux_hls',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
          ),
          VGStreamingManifestSpec(
            key: 'shaka_dash',
            uri: Uri.parse(
              'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
            ),
            formatHint: VGStreamingFormatHint.dash,
          ),
        ],
        requestedNetworkProfile: VGStreamingNetworkProfile.constrained,
        preferLowLatency: true,
        allowLowLatencyOnConstrained: true,
      );

      final args = request.toArgs();
      final manifests = args['manifests'] as List<Map<String, Object?>>;
      expect(manifests.length, equals(2));
      expect(manifests[0]['key'], equals('mux_hls'));
      expect(manifests[0]['formatHint'], equals('HLS'));
      expect(manifests[1]['key'], equals('shaka_dash'));
      expect(manifests[1]['formatHint'], equals('DASH'));
      expect(args['requestedNetworkProfile'], equals('CONSTRAINED'));
      expect(args['preferLowLatency'], isTrue);
      expect(args['allowLowLatencyOnConstrained'], isTrue);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. VGStreamingPreflightReport
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingPreflightReport', () {
    test('fromMap parses pass report including nested network policy', () {
      final rawMap = <Object?, Object?>{
        'phase': 'Phase4C5G',
        'pass': true,
        'advisoryDecision': 'advise_constrained',
        'requestedNetworkProfile': 'CONSTRAINED',
        'recommendedNetworkProfile': 'CONSTRAINED',
        'recommendedNetworkPolicy': <Object?, Object?>{
          'phase': 'Phase4C5B',
          'profile': 'CONSTRAINED',
          'minBufferMs': 15000,
          'maxBufferMs': 30000,
          'bufferForPlaybackMs': 2500,
          'bufferForPlaybackAfterRebufferMs': 5000,
          'maxInitialBitrateBps': 1500000,
        },
        'totalReports': 3,
        'passedReports': 3,
        'failedReports': 0,
        'warnings': <Object?>['warning_one'],
        'deviceWarnings': <Object?>['av1_software_only'],
        'llHlsAvailable': true,
        'advisoryOnly': true,
        'playbackMutation': false,
        'serverLadderPolicy': 'add_hevc_av1_renditions_but_keep_avc_fallback',
        'iosMirrorNote': 'iOS AVPlayer mirror guidance',
        'raw': 'status=OK;decision=advise_constrained',
        100: 'non_string_key_value',
      };

      final report = VGStreamingPreflightReport.fromMap(rawMap);
      expect(report.pass, isTrue);
      expect(report.phase, equals('Phase4C5G'));
      expect(report.advisoryDecision, equals('advise_constrained'));
      expect(report.requestedNetworkProfile, equals('CONSTRAINED'));
      expect(report.recommendedNetworkProfile, equals('CONSTRAINED'));
      expect(report.recommendedNetworkPolicy['profile'], equals('CONSTRAINED'));
      expect(report.recommendedNetworkPolicy['minBufferMs'], equals(15000));
      expect(report.totalReports, equals(3));
      expect(report.passedReports, equals(3));
      expect(report.failedReports, equals(0));
      expect(report.warnings, equals(['warning_one']));
      expect(report.deviceWarnings, equals(['av1_software_only']));
      expect(report.llHlsAvailable, isTrue);
      expect(report.advisoryOnly, isTrue);
      expect(report.playbackMutation, isFalse);
      expect(
        report.serverLadderPolicy,
        equals('add_hevc_av1_renditions_but_keep_avc_fallback'),
      );
      expect(report.iosMirrorNote, equals('iOS AVPlayer mirror guidance'));
      expect(report.raw, equals('status=OK;decision=advise_constrained'));
      expect(report.diagnostics['100'], equals('non_string_key_value'));
    });

    test('fromMap handles missing/null values defensively', () {
      final rawMap = <Object?, Object?>{
        'pass': false,
        'advisoryDecision': 'blocked_no_manifest_specs',
      };

      final report = VGStreamingPreflightReport.fromMap(rawMap);
      expect(report.pass, isFalse);
      expect(report.phase, equals('Phase4C5G'));
      expect(report.advisoryDecision, equals('blocked_no_manifest_specs'));
      expect(report.requestedNetworkProfile, equals(''));
      expect(report.recommendedNetworkProfile, equals(''));
      expect(report.recommendedNetworkPolicy, isEmpty);
      expect(report.totalReports, equals(0));
      expect(report.passedReports, equals(0));
      expect(report.failedReports, equals(0));
      expect(report.warnings, isEmpty);
      expect(report.deviceWarnings, isEmpty);
      expect(report.llHlsAvailable, isFalse);
      expect(report.advisoryOnly, isTrue);
      expect(report.playbackMutation, isFalse);
      expect(report.serverLadderPolicy, equals(''));
      expect(report.iosMirrorNote, equals(''));
      expect(report.raw, equals(''));
    });

    test('unsupported factory returns safe typed fallback', () {
      final report = VGStreamingPreflightReport.unsupported();
      expect(report.pass, isFalse);
      expect(report.phase, equals('unsupported'));
      expect(report.advisoryDecision, equals('unsupported'));
      expect(report.requestedNetworkProfile, equals('AUTO'));
      expect(report.recommendedNetworkProfile, equals('CONSTRAINED'));
      expect(report.recommendedNetworkPolicy['profile'], equals('CONSTRAINED'));
      expect(report.totalReports, equals(0));
      expect(report.passedReports, equals(0));
      expect(report.failedReports, equals(0));
      expect(report.warnings, contains('unsupported_platform'));
      expect(report.deviceWarnings, isEmpty);
      expect(report.llHlsAvailable, isFalse);
      expect(report.advisoryOnly, isTrue);
      expect(report.playbackMutation, isFalse);
      expect(report.raw, contains('UNSUPPORTED'));
      expect(report.toString(), contains('unsupported'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. VGStreamingPreflightClient MethodChannel contract
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingPreflightClient', () {
    test(
      'evaluate calls evaluateStreamingPreflightAdvisory route and parses response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'evaluateStreamingPreflightAdvisory') {
            return <Object?, Object?>{
              'phase': 'Phase4C5G',
              'pass': true,
              'advisoryDecision': 'advise_low_latency',
              'requestedNetworkProfile': 'LOW_LATENCY',
              'recommendedNetworkProfile': 'LOW_LATENCY',
              'recommendedNetworkPolicy': <Object?, Object?>{
                'profile': 'LOW_LATENCY',
                'minBufferMs': 2000,
                'maxBufferMs': 5000,
              },
              'totalReports': 1,
              'passedReports': 1,
              'failedReports': 0,
              'warnings': <Object?>[],
              'deviceWarnings': <Object?>[],
              'llHlsAvailable': true,
              'advisoryOnly': true,
              'playbackMutation': false,
              'serverLadderPolicy':
                  'add_hevc_av1_renditions_but_keep_avc_fallback',
              'iosMirrorNote': 'iOS mirror guidance',
              'raw': 'status=OK;decision=advise_low_latency',
            };
          }
          return null;
        });

        final client = VGStreamingPreflightClient(channel: channel);
        final request = VGStreamingPreflightRequest(
          manifests: [
            VGStreamingManifestSpec(
              key: 'll_hls_stream',
              uri: Uri.parse('https://stream.mux.com/ll_stream.m3u8'),
              formatHint: VGStreamingFormatHint.hls,
              requireLlHlsTags: true,
            ),
          ],
          requestedNetworkProfile: VGStreamingNetworkProfile.lowLatency,
          preferLowLatency: true,
        );

        final report = await client.evaluate(request);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('evaluateStreamingPreflightAdvisory'),
        );
        expect(
          recordedCall!.method,
          isNot(equals('runAndroidDagPhase4C5GPreflightAdvisorySmoke')),
        );

        final callArgs = recordedCall!.arguments as Map;
        expect(callArgs['requestedNetworkProfile'], equals('LOW_LATENCY'));
        expect(callArgs['preferLowLatency'], isTrue);
        expect(callArgs['allowLowLatencyOnConstrained'], isFalse);
        final callManifests = callArgs['manifests'] as List;
        expect(callManifests.length, equals(1));
        expect(callManifests[0]['key'], equals('ll_hls_stream'));
        expect(callManifests[0]['requireLlHlsTags'], isTrue);

        expect(report.pass, isTrue);
        expect(report.phase, equals('Phase4C5G'));
        expect(report.advisoryDecision, equals('advise_low_latency'));
        expect(report.recommendedNetworkProfile, equals('LOW_LATENCY'));
        expect(
          report.recommendedNetworkPolicy['profile'],
          equals('LOW_LATENCY'),
        );
        expect(report.llHlsAvailable, isTrue);
        expect(report.advisoryOnly, isTrue);
        expect(report.playbackMutation, isFalse);
      },
    );

    test(
      'evaluate returns unsupported report when response is non-map',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'evaluateStreamingPreflightAdvisory') {
            return 'not_a_map';
          }
          return null;
        });

        final client = VGStreamingPreflightClient(channel: channel);
        final request = VGStreamingPreflightRequest(
          manifests: [
            VGStreamingManifestSpec(
              key: 'stream',
              uri: Uri.parse('https://example.com/test.m3u8'),
            ),
          ],
        );

        final report = await client.evaluate(request);
        expect(report.pass, isFalse);
        expect(report.phase, equals('unsupported'));
        expect(report.advisoryDecision, equals('unsupported'));
      },
    );

    test(
      'evaluate returns unsupported report when MissingPluginException is thrown',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException('No implementation found for method');
        });

        final client = VGStreamingPreflightClient(channel: channel);
        final request = VGStreamingPreflightRequest(
          manifests: [
            VGStreamingManifestSpec(
              key: 'stream',
              uri: Uri.parse('https://example.com/test.m3u8'),
            ),
          ],
        );

        final report = await client.evaluate(request);
        expect(report.pass, isFalse);
        expect(report.phase, equals('unsupported'));
        expect(report.advisoryDecision, equals('unsupported'));
        expect(report.warnings, contains('unsupported_platform'));
      },
    );
  });
}
