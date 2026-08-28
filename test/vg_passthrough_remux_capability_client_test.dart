// Copyright (c) Connects -- Vanguard Phase 2-Unit AA.
// Public Android passthrough remux capability client Dart contract tests.

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

  // ---------------------------------------------------------------------------
  // 1. VGPassthroughRemuxTrackCapability
  // ---------------------------------------------------------------------------
  group('VGPassthroughRemuxTrackCapability', () {
    test('fromMap parses valid video track and converts toMap', () {
      final map = <Object?, Object?>{
        'trackIndex': 0,
        'mime': 'video/avc',
        'supported': true,
        'reason': 'supported',
        'width': 1920,
        'height': 1080,
        'durationUs': 5000000,
        'rotationDegrees': 90,
        'maxInputSize': 1048576,
        'customExtra': 'preserved',
      };

      final track = VGPassthroughRemuxTrackCapability.fromMap(map);
      expect(track.trackIndex, equals(0));
      expect(track.mime, equals('video/avc'));
      expect(track.supported, isTrue);
      expect(track.reason, equals('supported'));
      expect(track.width, equals(1920));
      expect(track.height, equals(1080));
      expect(track.durationUs, equals(5000000));
      expect(track.rotationDegrees, equals(90));
      expect(track.channelCount, isNull);
      expect(track.sampleRate, isNull);
      expect(track.maxInputSize, equals(1048576));
      expect(track.isVideo, isTrue);
      expect(track.isAudio, isFalse);
      expect(track.diagnostics['customExtra'], equals('preserved'));

      final roundTrip = track.toMap();
      expect(roundTrip['trackIndex'], equals(0));
      expect(roundTrip['mime'], equals('video/avc'));
      expect(roundTrip['supported'], isTrue);
      expect(roundTrip['reason'], equals('supported'));
      expect(roundTrip['width'], equals(1920));
      expect(roundTrip['height'], equals(1080));
      expect(roundTrip['durationUs'], equals(5000000));
      expect(roundTrip['rotationDegrees'], equals(90));
      expect(roundTrip['maxInputSize'], equals(1048576));
      expect(roundTrip['channelCount'], isNull);
      expect(roundTrip['sampleRate'], isNull);
      expect(track.toString(), contains('trackIndex: 0'));
    });

    test('fromMap parses valid audio track and converts toMap', () {
      final map = <Object?, Object?>{
        'trackIndex': 1,
        'mime': 'audio/mp4a-latm',
        'supported': true,
        'reason': 'supported',
        'durationUs': 5000000,
        'channelCount': 2,
        'sampleRate': 44100,
        'maxInputSize': 32768,
      };

      final track = VGPassthroughRemuxTrackCapability.fromMap(map);
      expect(track.trackIndex, equals(1));
      expect(track.mime, equals('audio/mp4a-latm'));
      expect(track.supported, isTrue);
      expect(track.reason, equals('supported'));
      expect(track.width, isNull);
      expect(track.height, isNull);
      expect(track.durationUs, equals(5000000));
      expect(track.rotationDegrees, isNull);
      expect(track.channelCount, equals(2));
      expect(track.sampleRate, equals(44100));
      expect(track.maxInputSize, equals(32768));
      expect(track.isVideo, isFalse);
      expect(track.isAudio, isTrue);

      final roundTrip = track.toMap();
      expect(roundTrip['trackIndex'], equals(1));
      expect(roundTrip['mime'], equals('audio/mp4a-latm'));
      expect(roundTrip['channelCount'], equals(2));
      expect(roundTrip['sampleRate'], equals(44100));
    });

    test('fromMap parses defensively with missing or malformed fields', () {
      final map = <Object?, Object?>{
        'trackIndex': 'not_an_int',
        'supported': null,
        'width': 1920.7,
        'height': 'invalid',
        'durationUs': 1000000.0,
      };

      final track = VGPassthroughRemuxTrackCapability.fromMap(map);
      expect(track.trackIndex, equals(-1));
      expect(track.mime, equals(''));
      expect(track.supported, isFalse);
      expect(track.reason, equals(''));
      expect(track.width, equals(1920));
      expect(track.height, isNull);
      expect(track.durationUs, equals(1000000));
      expect(track.isVideo, isFalse);
      expect(track.isAudio, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 2. VGPassthroughRemuxCapabilityReport
  // ---------------------------------------------------------------------------
  group('VGPassthroughRemuxCapabilityReport', () {
    test(
      'fromMap parses valid platform report with nested video, audio, and nonClaims',
      () {
        final rawMap = <Object?, Object?>{
          'canPassthroughRemux': true,
          'reason': 'supported',
          'sourcePath': '/data/user/0/cache/sample.mp4',
          'fileExists': true,
          'fileReadable': true,
          'extractorOpened': true,
          'trackCount': 2,
          'video': <Object?, Object?>{
            'trackIndex': 0,
            'mime': 'video/avc',
            'supported': true,
            'reason': 'supported',
            'width': 1280,
            'height': 720,
            'durationUs': 10000000,
            'rotationDegrees': 0,
          },
          'audio': <Object?, Object?>{
            'trackIndex': 1,
            'mime': 'audio/mp4a-latm',
            'supported': true,
            'reason': 'supported',
            'channelCount': 2,
            'sampleRate': 48000,
          },
          'proofBoundary':
              'native_passthrough_remux_capability_probe_no_mux_no_decode_no_samples',
          'nonClaims': <Object?, Object?>{
            'mediaMuxerStarted': false,
            'mediaCodecAllocated': false,
            'samplesRead': false,
            'outputFileWritten': false,
            'productionExportTimelineBypass': false,
            'cppPassthroughRemuxSinkNode': false,
            'connectAppTouched': false,
          },
          'customTelemetry': 'telemetry_value',
        };

        final report = VGPassthroughRemuxCapabilityReport.fromMap(rawMap);
        expect(report.canPassthroughRemux, isTrue);
        expect(report.reason, equals('supported'));
        expect(report.sourcePath, equals('/data/user/0/cache/sample.mp4'));
        expect(report.fileExists, isTrue);
        expect(report.fileReadable, isTrue);
        expect(report.extractorOpened, isTrue);
        expect(report.trackCount, equals(2));
        expect(report.video, isNotNull);
        expect(report.video!.mime, equals('video/avc'));
        expect(report.video!.width, equals(1280));
        expect(report.audio, isNotNull);
        expect(report.audio!.mime, equals('audio/mp4a-latm'));
        expect(report.audio!.sampleRate, equals(48000));
        expect(
          report.proofBoundary,
          equals(
            'native_passthrough_remux_capability_probe_no_mux_no_decode_no_samples',
          ),
        );
        expect(report.proofBoundaryMatches, isTrue);
        expect(report.hasSupportedVideo, isTrue);
        expect(report.hasSupportedAudioOrNoAudio, isTrue);
        expect(report.diagnosticNonClaimsHold, isTrue);
        expect(
          report.diagnostics['customTelemetry'],
          equals('telemetry_value'),
        );

        final roundTrip = report.toMap();
        expect(roundTrip['canPassthroughRemux'], isTrue);
        expect(
          roundTrip['sourcePath'],
          equals('/data/user/0/cache/sample.mp4'),
        );
        expect(roundTrip['video'], isA<Map<String, Object?>>());
        expect(roundTrip['audio'], isA<Map<String, Object?>>());
        expect(report.toString(), contains('canPassthroughRemux: true'));
      },
    );

    test('missing audio still satisfies hasSupportedAudioOrNoAudio', () {
      final rawMap = <Object?, Object?>{
        'canPassthroughRemux': true,
        'reason': 'supported',
        'sourcePath': '/data/user/0/cache/video_only.mp4',
        'fileExists': true,
        'fileReadable': true,
        'extractorOpened': true,
        'trackCount': 1,
        'video': <Object?, Object?>{
          'trackIndex': 0,
          'mime': 'video/hevc',
          'supported': true,
          'reason': 'supported',
        },
        'audio': null,
        'proofBoundary':
            'native_passthrough_remux_capability_probe_no_mux_no_decode_no_samples',
        'nonClaims': <Object?, Object?>{
          'mediaMuxerStarted': false,
          'mediaCodecAllocated': false,
          'samplesRead': false,
          'outputFileWritten': false,
          'productionExportTimelineBypass': false,
          'cppPassthroughRemuxSinkNode': false,
          'connectAppTouched': false,
        },
      };

      final report = VGPassthroughRemuxCapabilityReport.fromMap(rawMap);
      expect(report.audio, isNull);
      expect(report.hasSupportedAudioOrNoAudio, isTrue);
      expect(report.hasSupportedVideo, isTrue);
      expect(report.canPassthroughRemux, isTrue);
    });

    test(
      'fromMap parses defensively when fields and nested maps are missing or malformed',
      () {
        final rawMap = <Object?, Object?>{
          'canPassthroughRemux': 'not_a_bool',
          'trackCount': 3.14,
          'video': 'invalid_video',
          'audio': 42,
          'nonClaims': 'invalid_non_claims',
        };

        final report = VGPassthroughRemuxCapabilityReport.fromMap(rawMap);
        expect(report.canPassthroughRemux, isFalse);
        expect(report.reason, equals(''));
        expect(report.sourcePath, equals(''));
        expect(report.fileExists, isFalse);
        expect(report.fileReadable, isFalse);
        expect(report.extractorOpened, isFalse);
        expect(report.trackCount, equals(3));
        expect(report.video, isNull);
        expect(report.audio, isNull);
        expect(report.proofBoundary, equals(''));
        expect(report.proofBoundaryMatches, isFalse);
        expect(report.hasSupportedVideo, isFalse);
        expect(report.hasSupportedAudioOrNoAudio, isTrue);
        expect(report.diagnosticNonClaimsHold, isFalse);
      },
    );

    test(
      'failure factory returns typed failure report with reason and details',
      () {
        final report = VGPassthroughRemuxCapabilityReport.failure(
          'file_not_found',
          <String, Object?>{'sourcePath': '/missing/file.mp4', 'code': 404},
        );
        expect(report.canPassthroughRemux, isFalse);
        expect(report.reason, equals('file_not_found'));
        expect(report.sourcePath, equals('/missing/file.mp4'));
        expect(report.fileExists, isFalse);
        expect(report.fileReadable, isFalse);
        expect(report.extractorOpened, isFalse);
        expect(report.trackCount, equals(0));
        expect(report.video, isNull);
        expect(report.audio, isNull);
        expect(report.proofBoundary, equals('client_failure'));
        expect(report.proofBoundaryMatches, isFalse);
        expect(report.diagnosticNonClaimsHold, isTrue);
        expect(report.diagnostics['code'], equals(404));
      },
    );

    test('unsupported factory returns typed fallback report', () {
      final report = VGPassthroughRemuxCapabilityReport.unsupported();
      expect(report.canPassthroughRemux, isFalse);
      expect(report.reason, equals('unsupported_platform'));
      expect(report.sourcePath, equals(''));
      expect(report.fileExists, isFalse);
      expect(report.fileReadable, isFalse);
      expect(report.extractorOpened, isFalse);
      expect(report.trackCount, equals(0));
      expect(report.video, isNull);
      expect(report.audio, isNull);
      expect(report.proofBoundary, equals('unsupported'));
      expect(report.proofBoundaryMatches, isFalse);
      expect(report.diagnosticNonClaimsHold, isTrue);
    });

    test(
      'diagnosticNonClaimsHold returns false when any non-claim is true or missing',
      () {
        final reportWithTrueClaim = VGPassthroughRemuxCapabilityReport.fromMap({
          'canPassthroughRemux': true,
          'proofBoundary':
              'native_passthrough_remux_capability_probe_no_mux_no_decode_no_samples',
          'nonClaims': <Object?, Object?>{
            'mediaMuxerStarted': true, // Violated non-claim!
            'mediaCodecAllocated': false,
            'samplesRead': false,
            'outputFileWritten': false,
            'productionExportTimelineBypass': false,
            'cppPassthroughRemuxSinkNode': false,
            'connectAppTouched': false,
          },
        });
        expect(reportWithTrueClaim.diagnosticNonClaimsHold, isFalse);

        final reportWithMissingKey = VGPassthroughRemuxCapabilityReport.fromMap(
          {
            'canPassthroughRemux': true,
            'nonClaims': <Object?, Object?>{
              'mediaMuxerStarted': false,
              // Missing mediaCodecAllocated and others
            },
          },
        );
        expect(reportWithMissingKey.diagnosticNonClaimsHold, isFalse);

        final reportWithEmptyNonClaims =
            VGPassthroughRemuxCapabilityReport.fromMap({
              'canPassthroughRemux': true,
              'nonClaims': <Object?, Object?>{},
            });
        expect(reportWithEmptyNonClaims.diagnosticNonClaimsHold, isFalse);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // 3. VGPassthroughRemuxCapabilityClient MethodChannel Contract
  // ---------------------------------------------------------------------------
  group('VGPassthroughRemuxCapabilityClient', () {
    test(
      'probe dispatches exact method and args and parses valid response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'runAndroidPassthroughRemuxCapabilityProbeSmoke') {
            return <Object?, Object?>{
              'canPassthroughRemux': true,
              'reason': 'supported',
              'sourcePath': call.arguments['sourcePath'],
              'fileExists': true,
              'fileReadable': true,
              'extractorOpened': true,
              'trackCount': 2,
              'video': <Object?, Object?>{
                'trackIndex': 0,
                'mime': 'video/avc',
                'supported': true,
                'reason': 'supported',
                'width': 1920,
                'height': 1080,
              },
              'audio': <Object?, Object?>{
                'trackIndex': 1,
                'mime': 'audio/mp4a-latm',
                'supported': true,
                'reason': 'supported',
              },
              'proofBoundary':
                  'native_passthrough_remux_capability_probe_no_mux_no_decode_no_samples',
              'nonClaims': <Object?, Object?>{
                'mediaMuxerStarted': false,
                'mediaCodecAllocated': false,
                'samplesRead': false,
                'outputFileWritten': false,
                'productionExportTimelineBypass': false,
                'cppPassthroughRemuxSinkNode': false,
                'connectAppTouched': false,
              },
            };
          }
          return null;
        });

        final client = VGPassthroughRemuxCapabilityClient(channel: channel);
        final report = await client.probe('/test/path/video.mp4');

        expect(recordedCall, isNotNull);
        expect(
          recordedCall!.method,
          equals('runAndroidPassthroughRemuxCapabilityProbeSmoke'),
        );
        expect(
          recordedCall!.arguments,
          equals(<String, Object?>{'sourcePath': '/test/path/video.mp4'}),
        );

        expect(report.canPassthroughRemux, isTrue);
        expect(report.sourcePath, equals('/test/path/video.mp4'));
        expect(report.hasSupportedVideo, isTrue);
        expect(report.hasSupportedAudioOrNoAudio, isTrue);
        expect(report.proofBoundaryMatches, isTrue);
        expect(report.diagnosticNonClaimsHold, isTrue);
      },
    );

    test(
      'blank or empty sourcePath returns failure without calling MethodChannel',
      () async {
        var channelCalled = false;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          channelCalled = true;
          return null;
        });

        final client = VGPassthroughRemuxCapabilityClient(channel: channel);

        final reportEmpty = await client.probe('');
        expect(reportEmpty.canPassthroughRemux, isFalse);
        expect(reportEmpty.reason, equals('source_path_empty'));
        expect(reportEmpty.proofBoundary, equals('client_failure'));
        expect(reportEmpty.proofBoundaryMatches, isFalse);
        expect(channelCalled, isFalse);

        final reportBlank = await client.probe('   \t\n  ');
        expect(reportBlank.canPassthroughRemux, isFalse);
        expect(reportBlank.reason, equals('source_path_empty'));
        expect(reportBlank.proofBoundary, equals('client_failure'));
        expect(reportBlank.proofBoundaryMatches, isFalse);
        expect(channelCalled, isFalse);
      },
    );

    test('non-map response returns failure report', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'runAndroidPassthroughRemuxCapabilityProbeSmoke') {
          return 'unexpected_string';
        }
        return null;
      });

      final client = VGPassthroughRemuxCapabilityClient(channel: channel);
      final report = await client.probe('/test/valid.mp4');

      expect(report.canPassthroughRemux, isFalse);
      expect(report.reason, equals('invalid_response:String'));
      expect(report.proofBoundary, equals('client_failure'));
      expect(report.proofBoundaryMatches, isFalse);
    });

    test(
      'MissingPluginException fallback returns unsupported report',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException('No implementation found');
        });

        final client = VGPassthroughRemuxCapabilityClient(channel: channel);
        final report = await client.probe('/test/valid.mp4');

        expect(report.canPassthroughRemux, isFalse);
        expect(report.reason, equals('unsupported_platform'));
        expect(report.proofBoundary, equals('unsupported'));
        expect(report.proofBoundaryMatches, isFalse);
      },
    );

    test(
      'thrown exception fallback returns failure report with exception reason',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'PROBE_FAILED',
            message: 'Native failure occurred',
          );
        });

        final client = VGPassthroughRemuxCapabilityClient(channel: channel);
        final report = await client.probe('/test/valid.mp4');

        expect(report.canPassthroughRemux, isFalse);
        expect(
          report.reason,
          contains('exception:PlatformException(PROBE_FAILED'),
        );
        expect(report.proofBoundary, equals('client_failure'));
        expect(report.proofBoundaryMatches, isFalse);
      },
    );
  });
}
