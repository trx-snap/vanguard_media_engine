// Copyright (c) Connects — Vanguard Phase 4C5N.
// Public streaming compatibility decision API Dart contract tests.

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
  // 1. VGStreamingCompatibilityDecisionRequest
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingCompatibilityDecisionRequest', () {
    test('enforces non-empty manifests assertion', () {
      expect(
        () => VGStreamingCompatibilityDecisionRequest(
          manifests: const <VGStreamingManifestSpec>[],
        ),
        throwsAssertionError,
      );
    });

    test('toArgs serializes single and multiple specs correctly', () {
      final request = VGStreamingCompatibilityDecisionRequest(
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
          VGStreamingManifestSpec(
            key: 'shaka_angel_one_dash',
            uri: Uri.parse(
              'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
            ),
            formatHint: VGStreamingFormatHint.dash,
          ),
        ],
      );

      final args = request.toArgs();
      expect(args['manifests'], isA<List>());
      final list = args['manifests'] as List<Map<String, Object?>>;
      expect(list.length, equals(2));
      expect(list[0]['key'], equals('mux_hls_test'));
      expect(
        list[0]['uri'],
        equals('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
      );
      expect(list[0]['formatHint'], equals('HLS'));
      expect(list[0]['requireAdaptiveLadder'], isTrue);
      expect(list[0]['requireAvcFallback'], isTrue);
      expect(list[1]['key'], equals('shaka_angel_one_dash'));
      expect(list[1]['formatHint'], equals('DASH'));
      expect(request.toString(), contains('manifests=2'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGStreamingCompatibilityDecisionEntry
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingCompatibilityDecisionEntry', () {
    test(
      'fromMap parses valid platform entry and getters evaluate correctly',
      () {
        final rawEntry = <Object?, Object?>{
          'key': 'mux_hls_test',
          'uri': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
          'formatHint': 'HLS',
          'pass': true,
          'manifestPolicyPass': true,
          'avcManifestPresent': true,
          'hevcManifestPresent': false,
          'av1ManifestPresent': false,
          'avcDeviceSupported': true,
          'hevcDeviceSupported': true,
          'av1DeviceSupported': true,
          'avcHardwareSafe': true,
          'hevcHardwareSafe': true,
          'av1HardwareSafe': false,
          'preferredCodecFamily': 'avc',
          'fallbackCodecFamily': 'avc',
          'safeCodecFamilies': <Object?>['avc'],
          'riskyCodecFamilies': <Object?>[],
          'warnings': <Object?>[],
          'renditionCount': 5,
          'lowestBandwidth': 300000,
          'highestBandwidth': 2500000,
          'decision': 'prefer_avc_fallback',
          'raw': 'status=OK;key=mux_hls_test;decision=prefer_avc_fallback',
          'manifestValidation': <Object?, Object?>{
            'pass': true,
            'variantCount': 5,
          },
        };

        final entry = VGStreamingCompatibilityDecisionEntry.fromMap(rawEntry);
        expect(entry.key, equals('mux_hls_test'));
        expect(
          entry.uri,
          equals('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
        );
        expect(entry.formatHint, equals('HLS'));
        expect(entry.pass, isTrue);
        expect(entry.manifestPolicyPass, isTrue);
        expect(entry.avcManifestPresent, isTrue);
        expect(entry.hevcManifestPresent, isFalse);
        expect(entry.av1ManifestPresent, isFalse);
        expect(entry.avcDeviceSupported, isTrue);
        expect(entry.hevcDeviceSupported, isTrue);
        expect(entry.av1DeviceSupported, isTrue);
        expect(entry.avcHardwareSafe, isTrue);
        expect(entry.hevcHardwareSafe, isTrue);
        expect(entry.av1HardwareSafe, isFalse);
        expect(entry.preferredCodecFamily, equals('avc'));
        expect(entry.fallbackCodecFamily, equals('avc'));
        expect(entry.safeCodecFamilies, equals(['avc']));
        expect(entry.riskyCodecFamilies, isEmpty);
        expect(entry.warnings, isEmpty);
        expect(entry.renditionCount, equals(5));
        expect(entry.lowestBandwidth, equals(300000));
        expect(entry.highestBandwidth, equals(2500000));
        expect(entry.decision, equals('prefer_avc_fallback'));
        expect(entry.raw, contains('status=OK'));
        expect(entry.manifestValidation['variantCount'], equals(5));

        // Convenience getters
        expect(entry.blocked, isFalse);
        expect(entry.prefersAvcFallback, isTrue);
        expect(entry.prefersHardwareAdvancedCodec, isFalse);
        expect(entry.toString(), contains('decision=prefer_avc_fallback'));
      },
    );

    test('getters identify hardware advanced codecs and blocked decisions', () {
      final hwEntry = VGStreamingCompatibilityDecisionEntry.fromMap({
        'key': 'hevc_stream',
        'decision': 'prefer_hevc_hardware',
        'preferredCodecFamily': 'hevc',
      });
      expect(hwEntry.blocked, isFalse);
      expect(hwEntry.prefersAvcFallback, isFalse);
      expect(hwEntry.prefersHardwareAdvancedCodec, isTrue);

      final av1HwEntry = VGStreamingCompatibilityDecisionEntry.fromMap({
        'key': 'av1_stream',
        'decision': 'prefer_av1_hardware',
        'preferredCodecFamily': 'av1',
      });
      expect(av1HwEntry.prefersHardwareAdvancedCodec, isTrue);

      final blockedEntry = VGStreamingCompatibilityDecisionEntry.fromMap({
        'key': 'bad_stream',
        'decision': 'blocked_no_safe_codec',
        'preferredCodecFamily': 'none',
      });
      expect(blockedEntry.blocked, isTrue);
      expect(blockedEntry.prefersAvcFallback, isFalse);
      expect(blockedEntry.prefersHardwareAdvancedCodec, isFalse);
    });

    test('fromMap handles missing and malformed fields defensively', () {
      final entry = VGStreamingCompatibilityDecisionEntry.fromMap({});
      expect(entry.key, equals(''));
      expect(entry.uri, equals(''));
      expect(entry.formatHint, equals('AUTO'));
      expect(entry.pass, isFalse);
      expect(entry.manifestPolicyPass, isFalse);
      expect(entry.avcManifestPresent, isFalse);
      expect(entry.hevcManifestPresent, isFalse);
      expect(entry.av1ManifestPresent, isFalse);
      expect(entry.avcDeviceSupported, isFalse);
      expect(entry.hevcDeviceSupported, isFalse);
      expect(entry.av1DeviceSupported, isFalse);
      expect(entry.avcHardwareSafe, isFalse);
      expect(entry.hevcHardwareSafe, isFalse);
      expect(entry.av1HardwareSafe, isFalse);
      expect(entry.preferredCodecFamily, equals('none'));
      expect(entry.fallbackCodecFamily, equals('none'));
      expect(entry.safeCodecFamilies, isEmpty);
      expect(entry.riskyCodecFamilies, isEmpty);
      expect(entry.warnings, isEmpty);
      expect(entry.renditionCount, equals(0));
      expect(entry.lowestBandwidth, equals(0));
      expect(entry.highestBandwidth, equals(0));
      expect(entry.decision, equals(''));
      expect(entry.raw, equals(''));
      expect(entry.manifestValidation, isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. VGStreamingCompatibilityDecisionReport
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingCompatibilityDecisionReport', () {
    test(
      'fromMap parses valid platform aggregate report and nested entries',
      () {
        final rawMap = <Object?, Object?>{
          'phase': 'Phase4C5E',
          'pass': true,
          'totalReports': 3,
          'passedReports': 3,
          'failedReports': 0,
          'codecProbePass': true,
          'avcSupported': true,
          'hevcSupported': true,
          'av1Supported': true,
          'av1HardwareSafe': false,
          'deviceWarnings': <Object?>['av1_software_only'],
          'serverLadderPolicy': 'add_hevc_av1_renditions_but_keep_avc_fallback',
          'iosMirrorNote': 'iOS AVPlayer guidance note',
          'reports': <Object?>[
            <Object?, Object?>{
              'key': 'hls_stream',
              'pass': true,
              'decision': 'prefer_avc_fallback',
              'preferredCodecFamily': 'avc',
            },
            <Object?, Object?>{
              'key': 'dash_stream',
              'pass': true,
              'decision': 'prefer_avc_fallback',
              'preferredCodecFamily': 'avc',
            },
            <Object?, Object?>{
              'key': 'll_hls_stream',
              'pass': true,
              'decision': 'prefer_avc_fallback',
              'preferredCodecFamily': 'avc',
            },
          ],
          'raw': 'status=OK;total=3;passed=3;failed=0',
          'extra_key': 42,
        };

        final report = VGStreamingCompatibilityDecisionReport.fromMap(rawMap);
        expect(report.pass, isTrue);
        expect(report.phase, equals('Phase4C5E'));
        expect(report.totalReports, equals(3));
        expect(report.passedReports, equals(3));
        expect(report.failedReports, equals(0));
        expect(report.codecProbePass, isTrue);
        expect(report.avcSupported, isTrue);
        expect(report.hevcSupported, isTrue);
        expect(report.av1Supported, isTrue);
        expect(report.av1HardwareSafe, isFalse);
        expect(report.deviceWarnings, equals(['av1_software_only']));
        expect(
          report.serverLadderPolicy,
          equals('add_hevc_av1_renditions_but_keep_avc_fallback'),
        );
        expect(report.iosMirrorNote, equals('iOS AVPlayer guidance note'));
        expect(report.reports.length, equals(3));
        expect(report.reports[0].key, equals('hls_stream'));
        expect(report.reports[1].key, equals('dash_stream'));
        expect(report.reports[2].key, equals('ll_hls_stream'));
        expect(report.raw, contains('status=OK'));
        expect(report.diagnostics['extra_key'], equals(42));

        // Convenience getters
        expect(report.allReportsPass, isTrue);
        expect(report.hasDeviceWarnings, isTrue);
        expect(report.av1SoftwareOnly, isTrue);
        expect(report.toString(), contains('Phase4C5E'));
      },
    );

    test('unsupported factory returns typed fallback report', () {
      final report = VGStreamingCompatibilityDecisionReport.unsupported();
      expect(report.pass, isFalse);
      expect(report.phase, equals('unsupported'));
      expect(report.totalReports, equals(0));
      expect(report.passedReports, equals(0));
      expect(report.failedReports, equals(0));
      expect(report.codecProbePass, isFalse);
      expect(report.avcSupported, isFalse);
      expect(report.hevcSupported, isFalse);
      expect(report.av1Supported, isFalse);
      expect(report.av1HardwareSafe, isFalse);
      expect(report.deviceWarnings, isEmpty);
      expect(report.serverLadderPolicy, equals(''));
      expect(report.iosMirrorNote, equals(''));
      expect(report.reports, isEmpty);
      expect(report.raw, contains('UNSUPPORTED'));
      expect(report.allReportsPass, isFalse);
      expect(report.hasDeviceWarnings, isFalse);
    });

    test('failure factory returns typed failure report with stable raw', () {
      final report = VGStreamingCompatibilityDecisionReport.failure(
        'network_timeout',
        {'code': 504},
      );
      expect(report.pass, isFalse);
      expect(report.phase, equals('Phase4C5E'));
      expect(report.raw, equals('status=FAIL;reason=network_timeout'));
      expect(report.diagnostics['code'], equals(504));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. VGStreamingCompatibilityDecisionClient MethodChannel Contract
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingCompatibilityDecisionClient', () {
    test(
      'evaluate dispatches to runAndroidDagPhase4C5ECompatibilityDecisionSmoke and parses response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method ==
              'runAndroidDagPhase4C5ECompatibilityDecisionSmoke') {
            return <Object?, Object?>{
              'phase': 'Phase4C5E',
              'pass': true,
              'totalReports': 1,
              'passedReports': 1,
              'failedReports': 0,
              'codecProbePass': true,
              'avcSupported': true,
              'hevcSupported': true,
              'av1Supported': true,
              'av1HardwareSafe': false,
              'deviceWarnings': <Object?>['av1_software_only'],
              'serverLadderPolicy':
                  'add_hevc_av1_renditions_but_keep_avc_fallback',
              'iosMirrorNote': 'iOS guidance',
              'reports': <Object?>[
                <Object?, Object?>{
                  'key': 'test_stream',
                  'uri': 'https://example.com/test.m3u8',
                  'formatHint': 'HLS',
                  'pass': true,
                  'manifestPolicyPass': true,
                  'avcManifestPresent': true,
                  'hevcManifestPresent': false,
                  'av1ManifestPresent': false,
                  'avcDeviceSupported': true,
                  'hevcDeviceSupported': true,
                  'av1DeviceSupported': true,
                  'avcHardwareSafe': true,
                  'hevcHardwareSafe': true,
                  'av1HardwareSafe': false,
                  'preferredCodecFamily': 'avc',
                  'fallbackCodecFamily': 'avc',
                  'safeCodecFamilies': <Object?>['avc'],
                  'riskyCodecFamilies': <Object?>[],
                  'warnings': <Object?>[],
                  'renditionCount': 3,
                  'lowestBandwidth': 500000,
                  'highestBandwidth': 1500000,
                  'decision': 'prefer_avc_fallback',
                  'raw': 'status=OK;key=test_stream',
                  'manifestValidation': <Object?, Object?>{'pass': true},
                },
              ],
              'raw': 'status=OK;total=1;passed=1',
            };
          }
          return null;
        });

        final client = VGStreamingCompatibilityDecisionClient(channel: channel);
        final request = VGStreamingCompatibilityDecisionRequest(
          manifests: [
            VGStreamingManifestSpec(
              key: 'test_stream',
              uri: Uri.parse('https://example.com/test.m3u8'),
              formatHint: VGStreamingFormatHint.hls,
            ),
          ],
        );

        final report = await client.evaluate(request);

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('runAndroidDagPhase4C5ECompatibilityDecisionSmoke'),
        );
        final callArgs = recordedCall!.arguments as Map;
        final manifestsList = callArgs['manifests'] as List;
        expect(manifestsList.length, equals(1));
        expect(manifestsList[0]['key'], equals('test_stream'));

        expect(report.pass, isTrue);
        expect(report.phase, equals('Phase4C5E'));
        expect(report.totalReports, equals(1));
        expect(report.passedReports, equals(1));
        expect(report.failedReports, equals(0));
        expect(report.reports.length, equals(1));
        expect(report.reports[0].key, equals('test_stream'));
        expect(report.reports[0].decision, equals('prefer_avc_fallback'));
        expect(report.reports[0].prefersAvcFallback, isTrue);
      },
    );

    test('evaluate returns failure report when response is non-map', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runAndroidDagPhase4C5ECompatibilityDecisionSmoke') {
          return 'invalid_string';
        }
        return null;
      });

      final client = VGStreamingCompatibilityDecisionClient(channel: channel);
      final request = VGStreamingCompatibilityDecisionRequest(
        manifests: [
          VGStreamingManifestSpec(
            key: 'stream',
            uri: Uri.parse('https://example.com/test.m3u8'),
          ),
        ],
      );

      final report = await client.evaluate(request);
      expect(report.pass, isFalse);
      expect(report.raw, contains('status=FAIL;reason=invalid_response:'));
    });

    test(
      'evaluate returns unsupported report when MissingPluginException is thrown',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException('No implementation found for method');
        });

        final client = VGStreamingCompatibilityDecisionClient(channel: channel);
        final request = VGStreamingCompatibilityDecisionRequest(
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
        expect(report.raw, contains('status=UNSUPPORTED'));
      },
    );

    test(
      'evaluate returns failure report when generic exception is thrown',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'NATIVE_ERROR',
            message: 'Channel error',
          );
        });

        final client = VGStreamingCompatibilityDecisionClient(channel: channel);
        final request = VGStreamingCompatibilityDecisionRequest(
          manifests: [
            VGStreamingManifestSpec(
              key: 'stream',
              uri: Uri.parse('https://example.com/test.m3u8'),
            ),
          ],
        );

        final report = await client.evaluate(request);
        expect(report.pass, isFalse);
        expect(report.raw, contains('status=FAIL;reason=exception:'));
      },
    );
  });
}
