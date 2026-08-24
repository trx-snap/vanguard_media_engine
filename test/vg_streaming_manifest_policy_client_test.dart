// Copyright (c) Connects — Vanguard Phase 4C5H.
// Public streaming manifest policy validation API Dart contract tests.

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
  // 1. VGStreamingManifestPolicyValidationRequest
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingManifestPolicyValidationRequest', () {
    test('enforces non-empty manifests assertion', () {
      expect(
        () => VGStreamingManifestPolicyValidationRequest(
          manifests: const <VGStreamingManifestSpec>[],
        ),
        throwsAssertionError,
      );
    });

    test('toArgs serializes single spec correctly', () {
      final request = VGStreamingManifestPolicyValidationRequest(
        manifests: [
          VGStreamingManifestSpec(
            key: 'mux_hls_test',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
            requireAdaptiveLadder: true,
            requireAvcFallback: true,
            requireLlHlsTags: false,
            allowMediaPlaylist: false,
          ),
        ],
      );

      final args = request.toArgs();
      expect(args['manifests'], isA<List>());
      final list = args['manifests'] as List<Map<String, Object?>>;
      expect(list.length, equals(1));
      expect(list[0]['key'], equals('mux_hls_test'));
      expect(
        list[0]['uri'],
        equals('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
      );
      expect(list[0]['formatHint'], equals('HLS'));
      expect(list[0]['requireAdaptiveLadder'], isTrue);
      expect(list[0]['requireAvcFallback'], isTrue);
      expect(list[0]['requireLlHlsTags'], isFalse);
      expect(list[0]['allowMediaPlaylist'], isFalse);
    });

    test('toArgs serializes multiple specs across HLS, DASH, and LL-HLS', () {
      final request = VGStreamingManifestPolicyValidationRequest(
        manifests: [
          VGStreamingManifestSpec(
            key: 'mux_hls_test',
            uri: Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            formatHint: VGStreamingFormatHint.hls,
          ),
          VGStreamingManifestSpec(
            key: 'shaka_angel_one_dash',
            uri: Uri.parse(
              'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
            ),
            formatHint: VGStreamingFormatHint.dash,
          ),
          VGStreamingManifestSpec(
            key: 'mux_ll_hls_test',
            uri: Uri.parse(
              'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
            ),
            formatHint: VGStreamingFormatHint.hls,
            requireLlHlsTags: true,
          ),
        ],
      );

      final args = request.toArgs();
      final list = args['manifests'] as List<Map<String, Object?>>;
      expect(list.length, equals(3));
      expect(list[0]['key'], equals('mux_hls_test'));
      expect(list[0]['formatHint'], equals('HLS'));
      expect(list[1]['key'], equals('shaka_angel_one_dash'));
      expect(list[1]['formatHint'], equals('DASH'));
      expect(list[2]['key'], equals('mux_ll_hls_test'));
      expect(list[2]['requireLlHlsTags'], isTrue);
      expect(request.toString(), contains('manifests=3'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGStreamingManifestPolicyValidationReport
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingManifestPolicyValidationReport', () {
    test('fromMap parses valid platform report and nested maps', () {
      final rawMap = <Object?, Object?>{
        'phase': 'Phase4C5D',
        'pass': true,
        'totalManifestsValidated': 3,
        'passedManifests': 3,
        'failedManifests': 0,
        'segmentRejectionPass': true,
        'serverLadderPolicy': 'add_hevc_av1_renditions_but_keep_avc_fallback',
        'iosMirrorNote':
            'iOS AVPlayer/HLS implementations must mirror AVC fallback requirement',
        'results': <Object?>[
          <Object?, Object?>{
            'key': 'mux_hls_test',
            'pass': true,
            'variantCount': 5,
          },
          <Object?, Object?>{
            'key': 'shaka_angel_one_dash',
            'pass': true,
            'representationCount': 8,
          },
          <Object?, Object?>{
            'key': 'mux_ll_hls_test',
            'pass': true,
            'llHlsTagsFound': true,
          },
        ],
        'segmentRejectionResult': <Object?, Object?>{
          'key': 'segment_rejection_probe',
          'fetchSuccess': false,
          'rejectedBeforeFetch': true,
        },
        'raw':
            'status=OK;total=3;passed=3;failed=0;segmentRejectionPass=true;allManifestsPass=true',
        100: 'custom_metadata',
      };

      final report = VGStreamingManifestPolicyValidationReport.fromMap(rawMap);
      expect(report.pass, isTrue);
      expect(report.phase, equals('Phase4C5D'));
      expect(report.totalManifestsValidated, equals(3));
      expect(report.passedManifests, equals(3));
      expect(report.failedManifests, equals(0));
      expect(report.segmentRejectionPass, isTrue);
      expect(
        report.serverLadderPolicy,
        equals('add_hevc_av1_renditions_but_keep_avc_fallback'),
      );
      expect(
        report.iosMirrorNote,
        contains('iOS AVPlayer/HLS implementations'),
      );
      expect(report.results.length, equals(3));
      expect(report.results[0]['key'], equals('mux_hls_test'));
      expect(report.results[0]['variantCount'], equals(5));
      expect(report.results[1]['key'], equals('shaka_angel_one_dash'));
      expect(report.results[2]['llHlsTagsFound'], isTrue);
      expect(report.segmentRejectionResult['fetchSuccess'], isFalse);
      expect(report.segmentRejectionResult['rejectedBeforeFetch'], isTrue);
      expect(report.raw, contains('status=OK'));
      expect(report.diagnostics['100'], equals('custom_metadata'));
    });

    test('fromMap handles missing and malformed fields defensively', () {
      final rawMap = <Object?, Object?>{
        'pass': false,
        'totalManifestsValidated': 2.0, // double value
        'results': 'not_a_list',
        'segmentRejectionResult': 'not_a_map',
      };

      final report = VGStreamingManifestPolicyValidationReport.fromMap(rawMap);
      expect(report.pass, isFalse);
      expect(report.phase, equals('Phase4C5D'));
      expect(report.totalManifestsValidated, equals(2));
      expect(report.passedManifests, equals(0));
      expect(report.failedManifests, equals(0));
      expect(report.segmentRejectionPass, isFalse);
      expect(report.serverLadderPolicy, equals(''));
      expect(report.iosMirrorNote, equals(''));
      expect(report.results, isEmpty);
      expect(report.segmentRejectionResult, isEmpty);
      expect(report.raw, equals(''));
    });

    test('unsupported factory returns typed fallback report', () {
      final report = VGStreamingManifestPolicyValidationReport.unsupported();
      expect(report.pass, isFalse);
      expect(report.phase, equals('unsupported'));
      expect(report.totalManifestsValidated, equals(0));
      expect(report.passedManifests, equals(0));
      expect(report.failedManifests, equals(0));
      expect(report.segmentRejectionPass, isFalse);
      expect(report.serverLadderPolicy, equals(''));
      expect(report.results, isEmpty);
      expect(report.segmentRejectionResult, isEmpty);
      expect(report.raw, contains('UNSUPPORTED'));
      expect(report.toString(), contains('unsupported'));
    });

    test('failure factory returns typed failure report with stable raw', () {
      final report = VGStreamingManifestPolicyValidationReport.failure(
        'network_timeout',
        {'error_code': -1001},
      );
      expect(report.pass, isFalse);
      expect(report.phase, equals('Phase4C5D'));
      expect(report.raw, equals('status=FAIL;reason=network_timeout'));
      expect(report.diagnostics['error_code'], equals(-1001));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. VGStreamingManifestPolicyClient MethodChannel Contract
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingManifestPolicyClient', () {
    test(
      'validate dispatches to runAndroidDagPhase4C5DManifestPolicyValidation and parses response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'runAndroidDagPhase4C5DManifestPolicyValidation') {
            return <Object?, Object?>{
              'phase': 'Phase4C5D',
              'pass': true,
              'totalManifestsValidated': 3,
              'passedManifests': 3,
              'failedManifests': 0,
              'segmentRejectionPass': true,
              'serverLadderPolicy':
                  'add_hevc_av1_renditions_but_keep_avc_fallback',
              'iosMirrorNote': 'iOS mirror guidance',
              'results': <Object?>[
                <Object?, Object?>{'key': 'hls', 'pass': true},
                <Object?, Object?>{'key': 'dash', 'pass': true},
                <Object?, Object?>{'key': 'll_hls', 'pass': true},
              ],
              'segmentRejectionResult': <Object?, Object?>{
                'fetchSuccess': false,
                'rejected': true,
              },
              'raw': 'status=OK;total=3;passed=3;failed=0',
            };
          }
          return null;
        });

        final client = VGStreamingManifestPolicyClient(channel: channel);
        final request = VGStreamingManifestPolicyValidationRequest(
          manifests: [
            VGStreamingManifestSpec(
              key: 'hls',
              uri: Uri.parse(
                'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
              ),
              formatHint: VGStreamingFormatHint.hls,
            ),
            VGStreamingManifestSpec(
              key: 'dash',
              uri: Uri.parse(
                'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
              ),
              formatHint: VGStreamingFormatHint.dash,
            ),
            VGStreamingManifestSpec(
              key: 'll_hls',
              uri: Uri.parse(
                'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
              ),
              formatHint: VGStreamingFormatHint.hls,
            ),
          ],
        );

        final report = await client.validate(request);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('runAndroidDagPhase4C5DManifestPolicyValidation'),
        );
        final callArgs = recordedCall!.arguments as Map;
        final manifestsList = callArgs['manifests'] as List;
        expect(manifestsList.length, equals(3));
        expect(manifestsList[0]['key'], equals('hls'));
        expect(manifestsList[1]['key'], equals('dash'));
        expect(manifestsList[2]['key'], equals('ll_hls'));

        expect(report.pass, isTrue);
        expect(report.phase, equals('Phase4C5D'));
        expect(report.totalManifestsValidated, equals(3));
        expect(report.passedManifests, equals(3));
        expect(report.failedManifests, equals(0));
        expect(report.segmentRejectionPass, isTrue);
        expect(
          report.serverLadderPolicy,
          equals('add_hevc_av1_renditions_but_keep_avc_fallback'),
        );
        expect(report.results.length, equals(3));
        expect(report.segmentRejectionResult['rejected'], isTrue);
      },
    );

    test('validate returns failure report when response is non-map', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runAndroidDagPhase4C5DManifestPolicyValidation') {
          return 'unexpected_string_response';
        }
        return null;
      });

      final client = VGStreamingManifestPolicyClient(channel: channel);
      final request = VGStreamingManifestPolicyValidationRequest(
        manifests: [
          VGStreamingManifestSpec(
            key: 'stream',
            uri: Uri.parse('https://example.com/test.m3u8'),
          ),
        ],
      );

      final report = await client.validate(request);
      expect(report.pass, isFalse);
      expect(report.raw, contains('status=FAIL;reason=invalid_response:'));
    });

    test(
      'validate returns unsupported report when MissingPluginException is thrown',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException('No implementation found for method');
        });

        final client = VGStreamingManifestPolicyClient(channel: channel);
        final request = VGStreamingManifestPolicyValidationRequest(
          manifests: [
            VGStreamingManifestSpec(
              key: 'stream',
              uri: Uri.parse('https://example.com/test.m3u8'),
            ),
          ],
        );

        final report = await client.validate(request);
        expect(report.pass, isFalse);
        expect(report.phase, equals('unsupported'));
        expect(report.raw, contains('status=UNSUPPORTED'));
      },
    );

    test(
      'validate returns failure report when generic exception is thrown',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'NATIVE_ERROR',
            message: 'Channel failed',
          );
        });

        final client = VGStreamingManifestPolicyClient(channel: channel);
        final request = VGStreamingManifestPolicyValidationRequest(
          manifests: [
            VGStreamingManifestSpec(
              key: 'stream',
              uri: Uri.parse('https://example.com/test.m3u8'),
            ),
          ],
        );

        final report = await client.validate(request);
        expect(report.pass, isFalse);
        expect(report.raw, contains('status=FAIL;reason=exception:'));
      },
    );
  });
}
