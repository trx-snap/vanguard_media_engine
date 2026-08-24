// Copyright (c) Connects — Vanguard Phase 4C5J.
// Public streaming codec capability API Dart contract tests.

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
  // 1. VGStreamingCodecInfo
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingCodecInfo', () {
    test('fromMap parses valid codec info and converts toMap', () {
      final map = <Object?, Object?>{
        'codecKey': 'hevc',
        'mimeType': 'video/hevc',
        'supported': true,
        'hardwareDecoderPresent': true,
        'softwareDecoderPresent': false,
        'decoderCount': 1,
        'decoderNames': <Object?>['c2.exynos.hevc.decoder'],
        'profileLevelCount': 12,
      };

      final info = VGStreamingCodecInfo.fromMap(map);
      expect(info.codecKey, equals('hevc'));
      expect(info.mimeType, equals('video/hevc'));
      expect(info.supported, isTrue);
      expect(info.hardwareDecoderPresent, isTrue);
      expect(info.softwareDecoderPresent, isFalse);
      expect(info.decoderCount, equals(1));
      expect(info.decoderNames, equals(['c2.exynos.hevc.decoder']));
      expect(info.profileLevelCount, equals(12));

      final roundTrip = info.toMap();
      expect(roundTrip['codecKey'], equals('hevc'));
      expect(roundTrip['mimeType'], equals('video/hevc'));
      expect(roundTrip['supported'], isTrue);
      expect(roundTrip['hardwareDecoderPresent'], isTrue);
      expect(roundTrip['softwareDecoderPresent'], isFalse);
      expect(roundTrip['decoderCount'], equals(1));
      expect(roundTrip['decoderNames'], equals(['c2.exynos.hevc.decoder']));
      expect(roundTrip['profileLevelCount'], equals(12));
      expect(info.toString(), contains('key=hevc'));
    });

    test('fromMap parses defensively with missing or malformed fields', () {
      final map = <Object?, Object?>{
        'supported': null,
        'decoderCount': 2.5,
        'decoderNames': 'not_a_list',
        'profileLevelCount': null,
      };

      final info = VGStreamingCodecInfo.fromMap(map);
      expect(info.codecKey, equals(''));
      expect(info.mimeType, equals(''));
      expect(info.supported, isFalse);
      expect(info.hardwareDecoderPresent, isFalse);
      expect(info.softwareDecoderPresent, isFalse);
      expect(info.decoderCount, equals(2));
      expect(info.decoderNames, isEmpty);
      expect(info.profileLevelCount, equals(0));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGStreamingCodecCapabilityReport
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingCodecCapabilityReport', () {
    test('fromMap parses valid platform report and nested probe and codecs', () {
      final rawMap = <Object?, Object?>{
        'pass': true,
        'phase': 'Phase4C5A',
        'avcPass': true,
        'codecCountPass': true,
        'fallbackPolicyPass': true,
        'iosMirrorNotePass': true,
        'avcSupported': true,
        'hevcSupported': true,
        'av1Supported': true,
        'probe': <Object?, Object?>{
          'pass': true,
          'phase': 'Phase4C5A',
          'androidSdk': 36,
          'serverLadderPolicy': 'add_hevc_av1_renditions_but_keep_avc_fallback',
          'iosMirrorNote':
              'iOS implementer must mirror capability-based codec selection with AVFoundation/CoreMedia and keep H.264 fallback.',
          'codecs': <Object?>[
            <Object?, Object?>{
              'codecKey': 'avc',
              'mimeType': 'video/avc',
              'supported': true,
              'hardwareDecoderPresent': true,
              'softwareDecoderPresent': true,
              'decoderCount': 2,
              'decoderNames': <Object?>[
                'c2.exynos.h264.decoder',
                'c2.android.avc.decoder',
              ],
              'profileLevelCount': 16,
            },
            <Object?, Object?>{
              'codecKey': 'hevc',
              'mimeType': 'video/hevc',
              'supported': true,
              'hardwareDecoderPresent': true,
              'softwareDecoderPresent': true,
              'decoderCount': 2,
              'decoderNames': <Object?>[
                'c2.exynos.hevc.decoder',
                'c2.android.hevc.decoder',
              ],
              'profileLevelCount': 20,
            },
            <Object?, Object?>{
              'codecKey': 'av1',
              'mimeType': 'video/av01',
              'supported': true,
              'hardwareDecoderPresent': false,
              'softwareDecoderPresent': true,
              'decoderCount': 2,
              'decoderNames': <Object?>[
                'c2.android.av1-dav1d.decoder',
                'c2.android.av1.decoder',
              ],
              'profileLevelCount': 8,
            },
          ],
          'raw':
              'status=OK;avcSupported=true;hevcSupported=true;av1Supported=true;androidSdk=36',
        },
        'raw':
            'status=OK;avcPass=true;codecCountPass=true;fallbackPolicyPass=true;iosMirrorNotePass=true;hevcSupported=true;av1Supported=true',
        'custom_key': 'custom_val',
      };

      final report = VGStreamingCodecCapabilityReport.fromMap(rawMap);
      expect(report.pass, isTrue);
      expect(report.phase, equals('Phase4C5A'));
      expect(report.avcPass, isTrue);
      expect(report.codecCountPass, isTrue);
      expect(report.fallbackPolicyPass, isTrue);
      expect(report.iosMirrorNotePass, isTrue);
      expect(report.avcSupported, isTrue);
      expect(report.hevcSupported, isTrue);
      expect(report.av1Supported, isTrue);
      expect(report.androidSdk, equals(36));
      expect(
        report.serverLadderPolicy,
        equals('add_hevc_av1_renditions_but_keep_avc_fallback'),
      );
      expect(
        report.iosMirrorNote,
        contains(
          'iOS implementer must mirror capability-based codec selection',
        ),
      );
      expect(report.codecs.length, equals(3));
      expect(report.codecs[0].codecKey, equals('avc'));
      expect(report.codecs[0].hardwareDecoderPresent, isTrue);
      expect(report.codecs[1].codecKey, equals('hevc'));
      expect(report.codecs[1].hardwareDecoderPresent, isTrue);
      expect(report.codecs[2].codecKey, equals('av1'));
      expect(report.codecs[2].hardwareDecoderPresent, isFalse);
      expect(report.codecs[2].softwareDecoderPresent, isTrue);

      expect(report.hasHardwareHevc, isTrue);
      expect(report.hasHardwareAv1, isFalse);
      expect(report.advancedCodecTelemetryPresent, isTrue);
      expect(report.probe['androidSdk'], equals(36));
      expect(report.diagnostics['custom_key'], equals('custom_val'));
      expect(report.toString(), contains('avc=true'));
    });

    test('fromMap parses defensively when probe and fields are missing', () {
      final rawMap = <Object?, Object?>{'pass': false};

      final report = VGStreamingCodecCapabilityReport.fromMap(rawMap);
      expect(report.pass, isFalse);
      expect(report.phase, equals('Phase4C5A'));
      expect(report.avcPass, isFalse);
      expect(report.codecCountPass, isFalse);
      expect(report.fallbackPolicyPass, isFalse);
      expect(report.iosMirrorNotePass, isFalse);
      expect(report.avcSupported, isFalse);
      expect(report.hevcSupported, isFalse);
      expect(report.av1Supported, isFalse);
      expect(report.androidSdk, equals(0));
      expect(report.serverLadderPolicy, equals(''));
      expect(report.iosMirrorNote, equals(''));
      expect(report.codecs, isEmpty);
      expect(report.probe, isEmpty);
      expect(report.raw, equals(''));
      expect(report.hasHardwareHevc, isFalse);
      expect(report.hasHardwareAv1, isFalse);
      expect(report.advancedCodecTelemetryPresent, isFalse);
    });

    test('unsupported factory returns typed fallback report', () {
      final report = VGStreamingCodecCapabilityReport.unsupported();
      expect(report.pass, isFalse);
      expect(report.phase, equals('unsupported'));
      expect(report.avcPass, isFalse);
      expect(report.codecCountPass, isFalse);
      expect(report.fallbackPolicyPass, isFalse);
      expect(report.iosMirrorNotePass, isFalse);
      expect(report.avcSupported, isFalse);
      expect(report.hevcSupported, isFalse);
      expect(report.av1Supported, isFalse);
      expect(report.androidSdk, equals(0));
      expect(report.serverLadderPolicy, equals(''));
      expect(report.iosMirrorNote, equals(''));
      expect(report.codecs, isEmpty);
      expect(report.probe, isEmpty);
      expect(report.raw, contains('UNSUPPORTED'));
      expect(report.toString(), contains('unsupported'));
    });

    test(
      'failure factory returns typed failure report with reason and details',
      () {
        final report = VGStreamingCodecCapabilityReport.failure(
          'codec_probe_failed',
          {'error_code': 500},
        );
        expect(report.pass, isFalse);
        expect(report.phase, equals('Phase4C5A'));
        expect(report.raw, equals('status=FAIL;reason=codec_probe_failed'));
        expect(report.diagnostics['error_code'], equals(500));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. VGStreamingCodecCapabilityClient MethodChannel Contract
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingCodecCapabilityClient', () {
    test(
      'probe dispatches to runAndroidDagPhase4C5AStreamingCodecCapabilitySmoke and parses response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method ==
              'runAndroidDagPhase4C5AStreamingCodecCapabilitySmoke') {
            return <Object?, Object?>{
              'pass': true,
              'phase': 'Phase4C5A',
              'avcPass': true,
              'codecCountPass': true,
              'fallbackPolicyPass': true,
              'iosMirrorNotePass': true,
              'avcSupported': true,
              'hevcSupported': true,
              'av1Supported': true,
              'probe': <Object?, Object?>{
                'pass': true,
                'phase': 'Phase4C5A',
                'androidSdk': 36,
                'serverLadderPolicy':
                    'add_hevc_av1_renditions_but_keep_avc_fallback',
                'iosMirrorNote':
                    'iOS implementer must mirror capability-based codec selection with AVFoundation/CoreMedia and keep H.264 fallback.',
                'codecs': <Object?>[
                  <Object?, Object?>{
                    'codecKey': 'avc',
                    'mimeType': 'video/avc',
                    'supported': true,
                    'hardwareDecoderPresent': true,
                    'softwareDecoderPresent': false,
                    'decoderCount': 1,
                    'decoderNames': <Object?>['c2.exynos.h264.decoder'],
                    'profileLevelCount': 16,
                  },
                  <Object?, Object?>{
                    'codecKey': 'hevc',
                    'mimeType': 'video/hevc',
                    'supported': true,
                    'hardwareDecoderPresent': true,
                    'softwareDecoderPresent': false,
                    'decoderCount': 1,
                    'decoderNames': <Object?>['c2.exynos.hevc.decoder'],
                    'profileLevelCount': 20,
                  },
                  <Object?, Object?>{
                    'codecKey': 'av1',
                    'mimeType': 'video/av01',
                    'supported': true,
                    'hardwareDecoderPresent': false,
                    'softwareDecoderPresent': true,
                    'decoderCount': 1,
                    'decoderNames': <Object?>['c2.android.av1-dav1d.decoder'],
                    'profileLevelCount': 8,
                  },
                ],
                'raw': 'status=OK;avcSupported=true;androidSdk=36',
              },
              'raw':
                  'status=OK;avcPass=true;codecCountPass=true;fallbackPolicyPass=true',
            };
          }
          return null;
        });

        final client = VGStreamingCodecCapabilityClient(channel: channel);
        final report = await client.probe();

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('runAndroidDagPhase4C5AStreamingCodecCapabilitySmoke'),
        );
        expect(recordedCall!.arguments, isNull);

        expect(report.pass, isTrue);
        expect(report.phase, equals('Phase4C5A'));
        expect(report.avcPass, isTrue);
        expect(report.codecCountPass, isTrue);
        expect(report.fallbackPolicyPass, isTrue);
        expect(report.iosMirrorNotePass, isTrue);
        expect(report.avcSupported, isTrue);
        expect(report.hevcSupported, isTrue);
        expect(report.av1Supported, isTrue);
        expect(report.androidSdk, equals(36));
        expect(
          report.serverLadderPolicy,
          equals('add_hevc_av1_renditions_but_keep_avc_fallback'),
        );
        expect(report.codecs.length, equals(3));
        expect(report.hasHardwareHevc, isTrue);
        expect(report.hasHardwareAv1, isFalse);
      },
    );

    test('probe returns failure report when response is non-map', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method ==
            'runAndroidDagPhase4C5AStreamingCodecCapabilitySmoke') {
          return 'unexpected_string_response';
        }
        return null;
      });

      final client = VGStreamingCodecCapabilityClient(channel: channel);
      final report = await client.probe();
      expect(report.pass, isFalse);
      expect(report.raw, contains('status=FAIL;reason=invalid_response:'));
    });

    test(
      'probe returns unsupported report when MissingPluginException is thrown',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException('No implementation found for method');
        });

        final client = VGStreamingCodecCapabilityClient(channel: channel);
        final report = await client.probe();
        expect(report.pass, isFalse);
        expect(report.phase, equals('unsupported'));
        expect(report.raw, contains('status=UNSUPPORTED'));
      },
    );

    test(
      'probe returns failure report when generic exception is thrown',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'NATIVE_ERROR',
            message: 'Channel failed',
          );
        });

        final client = VGStreamingCodecCapabilityClient(channel: channel);
        final report = await client.probe();
        expect(report.pass, isFalse);
        expect(report.raw, contains('status=FAIL;reason=exception:'));
      },
    );
  });
}
