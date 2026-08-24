// Copyright (c) Connects — Vanguard Phase 4C5L.
// Public streaming manifest rendition diagnostics API Dart contract tests.

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
  // 1. VGStreamingRenditionInfo
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingRenditionInfo', () {
    test('fromMap parses valid rendition info and converts toMap', () {
      final map = <Object?, Object?>{
        'index': 0,
        'id': 'rep_1080p',
        'uri': 'https://example.com/stream_1080p.m3u8',
        'rawUri': 'stream_1080p.m3u8',
        'adaptationSetId': 'video_as',
        'bandwidth': 5000000,
        'averageBandwidth': 4800000,
        'resolution': '1920x1080',
        'width': 1920,
        'height': 1080,
        'codecs': 'avc1.640028,mp4a.40.2',
        'mimeType': 'video/mp4',
        'frameRate': 29.97,
        'name': '1080p High',
        'hasAvc': true,
        'hasHevc': false,
        'hasAv1': false,
        'detectedFamilies': <Object?>['avc', 'aac'],
        'extra_key': 'extra_val',
      };

      final info = VGStreamingRenditionInfo.fromMap(map);
      expect(info.index, equals(0));
      expect(info.id, equals('rep_1080p'));
      expect(info.uri, equals('https://example.com/stream_1080p.m3u8'));
      expect(info.rawUri, equals('stream_1080p.m3u8'));
      expect(info.adaptationSetId, equals('video_as'));
      expect(info.bandwidth, equals(5000000));
      expect(info.averageBandwidth, equals(4800000));
      expect(info.resolution, equals('1920x1080'));
      expect(info.width, equals(1920));
      expect(info.height, equals(1080));
      expect(info.codecs, equals('avc1.640028,mp4a.40.2'));
      expect(info.mimeType, equals('video/mp4'));
      expect(info.frameRate, equals('29.97'));
      expect(info.name, equals('1080p High'));
      expect(info.hasAvc, isTrue);
      expect(info.hasHevc, isFalse);
      expect(info.hasAv1, isFalse);
      expect(info.hasAdvancedCodec, isFalse);
      expect(info.detectedFamilies, equals(['avc', 'aac']));
      expect(info.diagnostics['extra_key'], equals('extra_val'));

      final roundTrip = info.toMap();
      expect(roundTrip['id'], equals('rep_1080p'));
      expect(roundTrip['bandwidth'], equals(5000000));
      expect(roundTrip['width'], equals(1920));
      expect(roundTrip['height'], equals(1080));
      expect(roundTrip['hasAvc'], isTrue);
      expect(info.toString(), contains('res=1920x1080'));
    });

    test('fromMap parses advanced codec flags correctly', () {
      final map = <Object?, Object?>{
        'index': 1,
        'id': 'rep_4k_hevc',
        'codecs': 'hvc1.2.4.L153.B0',
        'hasAvc': false,
        'hasHevc': true,
        'hasAv1': false,
        'detectedFamilies': <Object?>['hevc'],
      };

      final info = VGStreamingRenditionInfo.fromMap(map);
      expect(info.hasAvc, isFalse);
      expect(info.hasHevc, isTrue);
      expect(info.hasAv1, isFalse);
      expect(info.hasAdvancedCodec, isTrue);
    });

    test('fromMap handles missing and malformed fields defensively', () {
      final map = <Object?, Object?>{
        'bandwidth': null,
        'width': 1920.0,
        'detectedFamilies': 'invalid_string',
      };

      final info = VGStreamingRenditionInfo.fromMap(map);
      expect(info.index, equals(0));
      expect(info.id, equals(''));
      expect(info.uri, equals(''));
      expect(info.rawUri, equals(''));
      expect(info.adaptationSetId, equals(''));
      expect(info.bandwidth, equals(0));
      expect(info.averageBandwidth, equals(0));
      expect(info.resolution, equals(''));
      expect(info.width, equals(1920));
      expect(info.height, equals(0));
      expect(info.codecs, equals(''));
      expect(info.mimeType, equals(''));
      expect(info.frameRate, equals(''));
      expect(info.name, equals(''));
      expect(info.hasAvc, isFalse);
      expect(info.hasHevc, isFalse);
      expect(info.hasAv1, isFalse);
      expect(info.hasAdvancedCodec, isFalse);
      expect(info.detectedFamilies, isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGStreamingManifestStreamDiagnostics
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingManifestStreamDiagnostics', () {
    test('fromMap parses valid stream diagnostics and nested variants', () {
      final map = <Object?, Object?>{
        'format': 'HLS',
        'uri': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        'resolvedUri': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
        'fetchSuccess': true,
        'parseSuccess': true,
        'isMediaPlaylist': false,
        'variantCount': 2,
        'representationCount': 2,
        'hasAdaptiveLadder': true,
        'hasAvc': true,
        'hasHevc': false,
        'hasAv1': false,
        'serverPolicyPass': true,
        'llHlsIndicators': <Object?, Object?>{
          'hasExtXPart': true,
          'hasExtXServerControl': true,
          'hasExtXPreloadHint': false,
          'hasExtXPartInf': false,
          'isLlHls': true,
        },
        'variants': <Object?>[
          <Object?, Object?>{
            'index': 0,
            'bandwidth': 1200000,
            'codecs': 'avc1.64001f,mp4a.40.2',
            'hasAvc': true,
            'hasHevc': false,
            'hasAv1': false,
          },
          <Object?, Object?>{
            'index': 1,
            'bandwidth': 3000000,
            'codecs': 'hvc1.1.6.L93.B0',
            'hasAvc': false,
            'hasHevc': true,
            'hasAv1': false,
          },
        ],
        'raw': 'status=OK;format=HLS;variantCount=2',
      };

      final streamDiag = VGStreamingManifestStreamDiagnostics.fromMap(map);
      expect(streamDiag.format, equals('HLS'));
      expect(
        streamDiag.uri,
        equals('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
      );
      expect(streamDiag.fetchSuccess, isTrue);
      expect(streamDiag.parseSuccess, isTrue);
      expect(streamDiag.isMediaPlaylist, isFalse);
      expect(streamDiag.variantCount, equals(2));
      expect(streamDiag.representationCount, equals(2));
      expect(streamDiag.hasAdaptiveLadder, isTrue);
      expect(streamDiag.hasAvc, isTrue);
      expect(streamDiag.hasHevc, isFalse);
      expect(streamDiag.hasAv1, isFalse);
      expect(streamDiag.serverPolicyPass, isTrue);
      expect(streamDiag.hasAnyAdvancedCodecRendition, isTrue);
      expect(streamDiag.hasAvcFallback, isTrue);
      expect(streamDiag.hasLlHlsIndicators, isTrue);
      expect(streamDiag.llHlsIndicators['isLlHls'], isTrue);
      expect(streamDiag.variants.length, equals(2));
      expect(streamDiag.representations.length, equals(2));
      expect(streamDiag.variants[0].hasAvc, isTrue);
      expect(streamDiag.variants[1].hasHevc, isTrue);
      expect(streamDiag.raw, contains('status=OK'));

      final roundTrip = streamDiag.toMap();
      expect(roundTrip['format'], equals('HLS'));
      expect(roundTrip['variantCount'], equals(2));
      expect((roundTrip['variants'] as List).length, equals(2));
      expect(streamDiag.toString(), contains('format=HLS'));
    });

    test('empty factory produces safe zero-value diagnostics', () {
      final empty = VGStreamingManifestStreamDiagnostics.empty('DASH');
      expect(empty.format, equals('DASH'));
      expect(empty.uri, isEmpty);
      expect(empty.fetchSuccess, isFalse);
      expect(empty.parseSuccess, isFalse);
      expect(empty.variantCount, equals(0));
      expect(empty.representationCount, equals(0));
      expect(empty.hasAdaptiveLadder, isFalse);
      expect(empty.hasAvc, isFalse);
      expect(empty.hasHevc, isFalse);
      expect(empty.hasAv1, isFalse);
      expect(empty.serverPolicyPass, isFalse);
      expect(empty.hasAnyAdvancedCodecRendition, isFalse);
      expect(empty.hasAvcFallback, isFalse);
      expect(empty.hasLlHlsIndicators, isFalse);
      expect(empty.variants, isEmpty);
      expect(empty.representations, isEmpty);
    });

    test('fromMap handles missing and malformed fields defensively', () {
      final map = <Object?, Object?>{
        'fetchSuccess': null,
        'variants': 'not_a_list',
        'llHlsIndicators': 'not_a_map',
      };

      final streamDiag = VGStreamingManifestStreamDiagnostics.fromMap(map);
      expect(streamDiag.format, equals(''));
      expect(streamDiag.fetchSuccess, isFalse);
      expect(streamDiag.parseSuccess, isFalse);
      expect(streamDiag.variantCount, equals(0));
      expect(streamDiag.variants, isEmpty);
      expect(streamDiag.representations, isEmpty);
      expect(streamDiag.llHlsIndicators, isEmpty);
      expect(streamDiag.hasLlHlsIndicators, isFalse);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. VGStreamingManifestRenditionReport
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingManifestRenditionReport', () {
    test('fromMap parses valid platform report and nested streams', () {
      final rawMap = <Object?, Object?>{
        'pass': true,
        'phase': 'Phase4C5C',
        'hlsPass': true,
        'dashPass': true,
        'llHlsPass': true,
        'allServerPoliciesPass': true,
        'totalStreamsInspected': 3,
        'totalVariantsDiscovered': 20,
        'hlsVariantCount': 5,
        'dashRepresentationCount': 10,
        'llHlsVariantCount': 5,
        'serverLadderPolicy': 'add_hevc_av1_renditions_but_keep_avc_fallback',
        'iosMirrorNote':
            'iOS AVPlayer/AVFoundation manifest selection must maintain H.264/AVC fallback renditions alongside HEVC/AV1.',
        'hls': <Object?, Object?>{
          'format': 'HLS',
          'uri': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
          'fetchSuccess': true,
          'parseSuccess': true,
          'variantCount': 5,
          'hasAvc': true,
          'hasHevc': false,
          'hasAv1': false,
          'serverPolicyPass': true,
        },
        'dash': <Object?, Object?>{
          'format': 'DASH',
          'uri':
              'https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd',
          'fetchSuccess': true,
          'parseSuccess': true,
          'representationCount': 10,
          'hasAvc': true,
          'hasHevc': false,
          'hasAv1': true,
          'serverPolicyPass': true,
        },
        'llHls': <Object?, Object?>{
          'format': 'HLS',
          'uri':
              'https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8',
          'fetchSuccess': true,
          'parseSuccess': true,
          'variantCount': 5,
          'hasAvc': true,
          'hasHevc': false,
          'hasAv1': false,
          'serverPolicyPass': true,
          'llHlsIndicators': <Object?, Object?>{'isLlHls': true},
        },
        'raw':
            'status=OK;hlsPass=true(variants=5);dashPass=true(reps=10);llHlsPass=true(variants=5);totalVariants=20;allServerPoliciesPass=true',
        'custom_key': 'custom_value',
      };

      final report = VGStreamingManifestRenditionReport.fromMap(rawMap);
      expect(report.pass, isTrue);
      expect(report.phase, equals('Phase4C5C'));
      expect(report.hlsPass, isTrue);
      expect(report.dashPass, isTrue);
      expect(report.llHlsPass, isTrue);
      expect(report.allServerPoliciesPass, isTrue);
      expect(report.totalStreamsInspected, equals(3));
      expect(report.totalVariantsDiscovered, equals(20));
      expect(report.hlsVariantCount, equals(5));
      expect(report.dashRepresentationCount, equals(10));
      expect(report.llHlsVariantCount, equals(5));
      expect(
        report.serverLadderPolicy,
        equals('add_hevc_av1_renditions_but_keep_avc_fallback'),
      );
      expect(report.iosMirrorNote, contains('iOS AVPlayer/AVFoundation'));
      expect(report.hls.format, equals('HLS'));
      expect(report.hls.variantCount, equals(5));
      expect(report.dash.format, equals('DASH'));
      expect(report.dash.representationCount, equals(10));
      expect(report.dash.hasAv1, isTrue);
      expect(report.llHls.format, equals('HLS'));
      expect(report.llHls.variantCount, equals(5));
      expect(report.hasAnyAdvancedCodecRendition, isTrue);
      expect(report.hasAvcFallback, isTrue);
      expect(report.hasLlHlsIndicators, isTrue);
      expect(report.raw, contains('status=OK'));
      expect(report.diagnostics['custom_key'], equals('custom_value'));
      expect(report.toString(), contains('pass=true'));
    });

    test('fromMap handles missing and malformed fields defensively', () {
      final rawMap = <Object?, Object?>{
        'pass': false,
        'hls': 'invalid_map',
        'dash': null,
        'llHls': 123,
      };

      final report = VGStreamingManifestRenditionReport.fromMap(rawMap);
      expect(report.pass, isFalse);
      expect(report.phase, equals('Phase4C5C'));
      expect(report.hlsPass, isFalse);
      expect(report.dashPass, isFalse);
      expect(report.llHlsPass, isFalse);
      expect(report.allServerPoliciesPass, isFalse);
      expect(report.totalStreamsInspected, equals(0));
      expect(report.totalVariantsDiscovered, equals(0));
      expect(report.serverLadderPolicy, equals(''));
      expect(report.iosMirrorNote, equals(''));
      expect(report.hls.format, equals('HLS'));
      expect(report.dash.format, equals('DASH'));
      expect(report.llHls.format, equals('HLS'));
      expect(report.hasAnyAdvancedCodecRendition, isFalse);
      expect(report.hasAvcFallback, isFalse);
      expect(report.hasLlHlsIndicators, isFalse);
    });

    test('unsupported factory returns typed fallback report', () {
      final report = VGStreamingManifestRenditionReport.unsupported();
      expect(report.pass, isFalse);
      expect(report.phase, equals('unsupported'));
      expect(report.hlsPass, isFalse);
      expect(report.dashPass, isFalse);
      expect(report.llHlsPass, isFalse);
      expect(report.allServerPoliciesPass, isFalse);
      expect(report.totalStreamsInspected, equals(0));
      expect(report.totalVariantsDiscovered, equals(0));
      expect(report.serverLadderPolicy, equals(''));
      expect(report.iosMirrorNote, equals(''));
      expect(report.raw, contains('UNSUPPORTED'));
      expect(report.diagnostics['phase'], equals('unsupported'));
      expect(report.toString(), contains('unsupported'));
    });

    test(
      'failure factory returns typed failure report with reason and details',
      () {
        final report = VGStreamingManifestRenditionReport.failure(
          'network_timeout',
          {'error_code': 504},
        );
        expect(report.pass, isFalse);
        expect(report.phase, equals('Phase4C5C'));
        expect(report.raw, equals('status=FAIL;reason=network_timeout'));
        expect(report.diagnostics['error_code'], equals(504));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. VGStreamingManifestRenditionClient MethodChannel Contract
  // ─────────────────────────────────────────────────────────────────────────
  group('VGStreamingManifestRenditionClient', () {
    test(
      'inspectCanonicalStreams dispatches to runAndroidDagPhase4C5CManifestRenditionSmoke and parses response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'runAndroidDagPhase4C5CManifestRenditionSmoke') {
            return <Object?, Object?>{
              'pass': true,
              'phase': 'Phase4C5C',
              'hlsPass': true,
              'dashPass': true,
              'llHlsPass': true,
              'allServerPoliciesPass': true,
              'totalStreamsInspected': 3,
              'totalVariantsDiscovered': 20,
              'hlsVariantCount': 5,
              'dashRepresentationCount': 10,
              'llHlsVariantCount': 5,
              'serverLadderPolicy':
                  'add_hevc_av1_renditions_but_keep_avc_fallback',
              'iosMirrorNote': 'iOS mirror guidance',
              'hls': <Object?, Object?>{
                'format': 'HLS',
                'fetchSuccess': true,
                'parseSuccess': true,
                'variantCount': 5,
                'hasAvc': true,
                'hasHevc': false,
                'hasAv1': false,
                'serverPolicyPass': true,
              },
              'dash': <Object?, Object?>{
                'format': 'DASH',
                'fetchSuccess': true,
                'parseSuccess': true,
                'representationCount': 10,
                'hasAvc': true,
                'hasHevc': false,
                'hasAv1': false,
                'serverPolicyPass': true,
              },
              'llHls': <Object?, Object?>{
                'format': 'HLS',
                'fetchSuccess': true,
                'parseSuccess': true,
                'variantCount': 5,
                'hasAvc': true,
                'hasHevc': false,
                'hasAv1': false,
                'serverPolicyPass': true,
              },
              'raw':
                  'status=OK;hlsPass=true;dashPass=true;llHlsPass=true;totalVariants=20',
            };
          }
          return null;
        });

        final client = VGStreamingManifestRenditionClient(channel: channel);
        final report = await client.inspectCanonicalStreams();

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('runAndroidDagPhase4C5CManifestRenditionSmoke'),
        );
        expect(recordedCall!.arguments, isNull);

        expect(report.pass, isTrue);
        expect(report.phase, equals('Phase4C5C'));
        expect(report.hlsPass, isTrue);
        expect(report.dashPass, isTrue);
        expect(report.llHlsPass, isTrue);
        expect(report.allServerPoliciesPass, isTrue);
        expect(report.totalStreamsInspected, equals(3));
        expect(report.totalVariantsDiscovered, equals(20));
        expect(report.hlsVariantCount, equals(5));
        expect(report.dashRepresentationCount, equals(10));
        expect(report.llHlsVariantCount, equals(5));
        expect(
          report.serverLadderPolicy,
          equals('add_hevc_av1_renditions_but_keep_avc_fallback'),
        );
        expect(report.hls.fetchSuccess, isTrue);
        expect(report.dash.fetchSuccess, isTrue);
        expect(report.llHls.fetchSuccess, isTrue);
      },
    );

    test('inspect alias calls inspectCanonicalStreams', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runAndroidDagPhase4C5CManifestRenditionSmoke') {
          return <Object?, Object?>{
            'pass': true,
            'phase': 'Phase4C5C',
            'hlsPass': true,
            'dashPass': true,
            'llHlsPass': true,
            'allServerPoliciesPass': true,
            'totalStreamsInspected': 3,
            'totalVariantsDiscovered': 20,
          };
        }
        return null;
      });

      final client = VGStreamingManifestRenditionClient(channel: channel);
      final report = await client.inspect();
      expect(report.pass, isTrue);
      expect(report.totalStreamsInspected, equals(3));
    });

    test(
      'inspectCanonicalStreams returns failure report when response is non-map',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'runAndroidDagPhase4C5CManifestRenditionSmoke') {
            return 'unexpected_string_response';
          }
          return null;
        });

        final client = VGStreamingManifestRenditionClient(channel: channel);
        final report = await client.inspectCanonicalStreams();
        expect(report.pass, isFalse);
        expect(report.raw, contains('status=FAIL;reason=invalid_response:'));
      },
    );

    test(
      'inspectCanonicalStreams returns unsupported report when MissingPluginException is thrown',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException('No implementation found for method');
        });

        final client = VGStreamingManifestRenditionClient(channel: channel);
        final report = await client.inspectCanonicalStreams();
        expect(report.pass, isFalse);
        expect(report.phase, equals('unsupported'));
        expect(report.raw, contains('status=UNSUPPORTED'));
      },
    );

    test(
      'inspectCanonicalStreams returns failure report when generic exception is thrown',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'NATIVE_ERROR',
            message: 'Channel failed',
          );
        });

        final client = VGStreamingManifestRenditionClient(channel: channel);
        final report = await client.inspectCanonicalStreams();
        expect(report.pass, isFalse);
        expect(report.raw, contains('status=FAIL;reason=exception:'));
      },
    );
  });
}
