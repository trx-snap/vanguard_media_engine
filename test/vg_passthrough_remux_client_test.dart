// Copyright (c) Connects -- Vanguard Phase 2-Unit AE.
// Public Android passthrough remux execution client Dart contract tests.

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
  // 1. VGPassthroughRemuxRequest
  // ---------------------------------------------------------------------------
  group('VGPassthroughRemuxRequest', () {
    test('trims sourcePath and outputPath correctly', () {
      const request = VGPassthroughRemuxRequest(
        sourcePath: '  /data/user/0/cache/input.mov  \n',
        outputPath: '\t /data/user/0/cache/output.mp4   ',
      );

      expect(request.trimmedSourcePath, equals('/data/user/0/cache/input.mov'));
      expect(
        request.trimmedOutputPath,
        equals('/data/user/0/cache/output.mp4'),
      );
      expect(request.isValid, isTrue);
    });

    test('isValid returns false for blank or empty paths', () {
      const emptySource = VGPassthroughRemuxRequest(
        sourcePath: '   ',
        outputPath: '/valid/out.mp4',
      );
      expect(emptySource.isValid, isFalse);

      const emptyOutput = VGPassthroughRemuxRequest(
        sourcePath: '/valid/in.mov',
        outputPath: '',
      );
      expect(emptyOutput.isValid, isFalse);

      const bothEmpty = VGPassthroughRemuxRequest(
        sourcePath: '\t',
        outputPath: '  \n',
      );
      expect(bothEmpty.isValid, isFalse);
    });

    test(
      'clamps diagnosticHoldBeforeRemuxMs into 0..5000 and omits when null',
      () {
        const nullHold = VGPassthroughRemuxRequest(
          sourcePath: '/in.mov',
          outputPath: '/out.mp4',
        );
        expect(nullHold.clampedDiagnosticHoldBeforeRemuxMs, isNull);
        final nullArgs = nullHold.toChannelArguments();
        expect(nullArgs.containsKey('diagnosticHoldBeforeRemuxMs'), isFalse);
        expect(nullArgs['sourcePath'], equals('/in.mov'));
        expect(nullArgs['outputPath'], equals('/out.mp4'));

        const negativeHold = VGPassthroughRemuxRequest(
          sourcePath: '/in.mov',
          outputPath: '/out.mp4',
          diagnosticHoldBeforeRemuxMs: -1,
        );
        expect(negativeHold.clampedDiagnosticHoldBeforeRemuxMs, equals(0));
        expect(
          negativeHold.toChannelArguments()['diagnosticHoldBeforeRemuxMs'],
          equals(0),
        );

        const excessiveHold = VGPassthroughRemuxRequest(
          sourcePath: '/in.mov',
          outputPath: '/out.mp4',
          diagnosticHoldBeforeRemuxMs: 9999,
        );
        expect(excessiveHold.clampedDiagnosticHoldBeforeRemuxMs, equals(5000));
        expect(
          excessiveHold.toChannelArguments()['diagnosticHoldBeforeRemuxMs'],
          equals(5000),
        );

        const validHold = VGPassthroughRemuxRequest(
          sourcePath: '/in.mov',
          outputPath: '/out.mp4',
          diagnosticHoldBeforeRemuxMs: 1200,
        );
        expect(validHold.clampedDiagnosticHoldBeforeRemuxMs, equals(1200));
        expect(
          validHold.toChannelArguments()['diagnosticHoldBeforeRemuxMs'],
          equals(1200),
        );
      },
    );

    test('toString contains request details', () {
      const request = VGPassthroughRemuxRequest(
        sourcePath: '/in.mov',
        outputPath: '/out.mp4',
        diagnosticHoldBeforeRemuxMs: 100,
      );
      final str = request.toString();
      expect(str, contains('/in.mov'));
      expect(str, contains('/out.mp4'));
      expect(str, contains('100'));
    });
  });

  // ---------------------------------------------------------------------------
  // 2. VGPassthroughRemuxExecutionReport
  // ---------------------------------------------------------------------------
  group('VGPassthroughRemuxExecutionReport', () {
    test(
      'fromMap parses valid platform report with all Unit AD fields and converts toMap',
      () {
        final rawMap = <Object?, Object?>{
          'success': true,
          'path': '/data/user/0/cache/output.mp4',
          'outputPath': '/data/user/0/cache/output.mp4',
          'sourcePath': '/data/user/0/cache/input.mov',
          'width': 1920,
          'height': 1080,
          'rotationDegrees': 90,
          'durationSeconds': 3.5,
          'videoSamples': 105,
          'audioSamples': 160,
          'outputSizeBytes': 1048576,
          'hasAudioTrack': true,
          'exportRoiSidecarPath': '/data/user/0/cache/output.roi.json',
          'roiSidecarPath': '/data/user/0/cache/output.roi.json',
          'proofBoundary':
              'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
          'nonClaims': <Object?, Object?>{
            'mediaCodecAllocated': false,
            'productionExportTimelineBypass': false,
            'cppPassthroughRemuxSinkNode': false,
            'connectAppTouched': false,
          },
          'diagnosticHoldBeforeRemuxMs': 250,
          'customTelemetry': 'telemetry_val_123',
        };

        final report = VGPassthroughRemuxExecutionReport.fromMap(rawMap);

        expect(report.success, isTrue);
        expect(report.isFailure, isFalse);
        expect(report.path, equals('/data/user/0/cache/output.mp4'));
        expect(report.outputPath, equals('/data/user/0/cache/output.mp4'));
        expect(report.sourcePath, equals('/data/user/0/cache/input.mov'));
        expect(report.width, equals(1920));
        expect(report.height, equals(1080));
        expect(report.rotationDegrees, equals(90));
        expect(report.durationSeconds, equals(3.5));
        expect(report.videoSamples, equals(105));
        expect(report.audioSamples, equals(160));
        expect(report.outputSizeBytes, equals(1048576));
        expect(report.hasAudioTrack, isTrue);
        expect(
          report.exportRoiSidecarPath,
          equals('/data/user/0/cache/output.roi.json'),
        );
        expect(
          report.roiSidecarPath,
          equals('/data/user/0/cache/output.roi.json'),
        );
        expect(
          report.proofBoundary,
          equals(
            'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
          ),
        );
        expect(report.proofBoundaryMatches, isTrue);
        expect(report.outputWritten, isTrue);
        expect(report.diagnosticNonClaimsHold, isTrue);
        expect(report.diagnosticHoldBeforeRemuxMs, equals(250));
        expect(report.errorCode, isNull);
        expect(report.errorMessage, isNull);
        expect(
          report.diagnostics['customTelemetry'],
          equals('telemetry_val_123'),
        );

        final roundTrip = report.toMap();
        expect(roundTrip['success'], isTrue);
        expect(roundTrip['path'], equals('/data/user/0/cache/output.mp4'));
        expect(
          roundTrip['outputPath'],
          equals('/data/user/0/cache/output.mp4'),
        );
        expect(roundTrip['sourcePath'], equals('/data/user/0/cache/input.mov'));
        expect(roundTrip['width'], equals(1920));
        expect(roundTrip['height'], equals(1080));
        expect(roundTrip['rotationDegrees'], equals(90));
        expect(roundTrip['durationSeconds'], equals(3.5));
        expect(roundTrip['videoSamples'], equals(105));
        expect(roundTrip['audioSamples'], equals(160));
        expect(roundTrip['outputSizeBytes'], equals(1048576));
        expect(roundTrip['hasAudioTrack'], isTrue);
        expect(
          roundTrip['exportRoiSidecarPath'],
          equals('/data/user/0/cache/output.roi.json'),
        );
        expect(
          roundTrip['roiSidecarPath'],
          equals('/data/user/0/cache/output.roi.json'),
        );
        expect(
          roundTrip['proofBoundary'],
          equals(
            'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
          ),
        );
        expect(roundTrip['diagnosticHoldBeforeRemuxMs'], equals(250));
        expect(roundTrip['nonClaims'], isA<Map<String, bool>>());
        expect(report.toString(), contains('success: true'));
      },
    );

    test(
      'fromMap parses exportRoiSidecarPath, roiSidecarPath alias getter returns same path, and toMap includes both keys',
      () {
        const sidecar = '/data/user/0/cache/custom_roi.json';
        final rawMap = <Object?, Object?>{
          'success': true,
          'outputPath': '/data/user/0/cache/video.mp4',
          'exportRoiSidecarPath': sidecar,
          'roiSidecarPath': sidecar,
          'proofBoundary':
              'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
          'nonClaims': <Object?, Object?>{
            'mediaCodecAllocated': false,
            'productionExportTimelineBypass': false,
            'cppPassthroughRemuxSinkNode': false,
            'connectAppTouched': false,
          },
        };

        final report = VGPassthroughRemuxExecutionReport.fromMap(rawMap);
        expect(report.exportRoiSidecarPath, equals(sidecar));
        expect(report.roiSidecarPath, equals(sidecar));

        final map = report.toMap();
        expect(map['exportRoiSidecarPath'], equals(sidecar));
        expect(map['roiSidecarPath'], equals(sidecar));
      },
    );

    test(
      'fromMap backward compatibility: when map only contains roiSidecarPath, exportRoiSidecarPath and alias are populated',
      () {
        const sidecar = '/data/user/0/cache/legacy_roi.json';
        final rawMap = <Object?, Object?>{
          'success': true,
          'outputPath': '/data/user/0/cache/video.mp4',
          'roiSidecarPath': sidecar,
          'proofBoundary':
              'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
          'nonClaims': <Object?, Object?>{
            'mediaCodecAllocated': false,
            'productionExportTimelineBypass': false,
            'cppPassthroughRemuxSinkNode': false,
            'connectAppTouched': false,
          },
        };

        final report = VGPassthroughRemuxExecutionReport.fromMap(rawMap);
        expect(report.exportRoiSidecarPath, equals(sidecar));
        expect(report.roiSidecarPath, equals(sidecar));

        final map = report.toMap();
        expect(map['exportRoiSidecarPath'], equals(sidecar));
        expect(map['roiSidecarPath'], equals(sidecar));
      },
    );

    test(
      'outputWritten returns false when success is false or output size is zero/null',
      () {
        final successZeroSize = VGPassthroughRemuxExecutionReport.fromMap({
          'success': true,
          'outputSizeBytes': 0,
          'proofBoundary':
              'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
          'nonClaims': <Object?, Object?>{
            'mediaCodecAllocated': false,
            'productionExportTimelineBypass': false,
            'cppPassthroughRemuxSinkNode': false,
            'connectAppTouched': false,
          },
        });
        expect(successZeroSize.outputWritten, isFalse);

        final failedReport = VGPassthroughRemuxExecutionReport.fromMap({
          'success': false,
          'outputSizeBytes': 1024,
          'proofBoundary':
              'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
          'nonClaims': <Object?, Object?>{
            'mediaCodecAllocated': false,
            'productionExportTimelineBypass': false,
            'cppPassthroughRemuxSinkNode': false,
            'connectAppTouched': false,
          },
        });
        expect(failedReport.outputWritten, isFalse);
      },
    );

    test(
      'diagnosticNonClaimsHold returns false when any key is missing or true',
      () {
        final missingKeyReport = VGPassthroughRemuxExecutionReport.fromMap({
          'success': true,
          'proofBoundary':
              'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
          'nonClaims': <Object?, Object?>{
            'mediaCodecAllocated': false,
            'productionExportTimelineBypass': false,
            'cppPassthroughRemuxSinkNode': false,
            // connectAppTouched missing!
          },
        });
        expect(missingKeyReport.diagnosticNonClaimsHold, isFalse);

        final trueClaimReport = VGPassthroughRemuxExecutionReport.fromMap({
          'success': true,
          'proofBoundary':
              'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
          'nonClaims': <Object?, Object?>{
            'mediaCodecAllocated': true, // Violated non-claim!
            'productionExportTimelineBypass': false,
            'cppPassthroughRemuxSinkNode': false,
            'connectAppTouched': false,
          },
        });
        expect(trueClaimReport.diagnosticNonClaimsHold, isFalse);
      },
    );

    test('diagnosticNonClaimsHold returns false when extra key is present', () {
      final extraClaimReport = VGPassthroughRemuxExecutionReport.fromMap({
        'success': true,
        'proofBoundary':
            'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
        'nonClaims': <Object?, Object?>{
          'mediaCodecAllocated': false,
          'productionExportTimelineBypass': false,
          'cppPassthroughRemuxSinkNode': false,
          'connectAppTouched': false,
          'mediaMuxerStarted':
              false, // Extra advisory key not in standardNonClaims!
        },
      });
      expect(extraClaimReport.diagnosticNonClaimsHold, isFalse);
    });

    test('fromMap parses defensively with missing or malformed fields', () {
      final malformedMap = <Object?, Object?>{
        'success': 'not_a_bool',
        'width': 'not_a_num',
        'height': 720.8,
        'durationSeconds': '5.2',
        'nonClaims': 'invalid_non_claims_structure',
      };

      final report = VGPassthroughRemuxExecutionReport.fromMap(malformedMap);
      expect(report.success, isFalse);
      expect(report.isFailure, isTrue);
      expect(report.width, isNull);
      expect(report.height, equals(720));
      expect(report.durationSeconds, equals(5.2));
      expect(report.proofBoundary, equals(''));
      expect(report.proofBoundaryMatches, isFalse);
      expect(report.diagnosticNonClaimsHold, isFalse);
    });

    test('failure factory returns typed failure report', () {
      final report = VGPassthroughRemuxExecutionReport.failure(
        'FILE_UNREADABLE',
        'Cannot open source',
        <String, Object?>{'sourcePath': '/missing/file.mov', 'code': 404},
      );

      expect(report.success, isFalse);
      expect(report.isFailure, isTrue);
      expect(report.errorCode, equals('FILE_UNREADABLE'));
      expect(report.errorMessage, equals('Cannot open source'));
      expect(report.proofBoundary, equals('client_failure'));
      expect(report.proofBoundaryMatches, isFalse);
      expect(report.diagnosticNonClaimsHold, isTrue);
      expect(report.diagnostics['code'], equals(404));
      expect(report.diagnostics['sourcePath'], equals('/missing/file.mov'));

      final defaultReport = VGPassthroughRemuxExecutionReport.failure(
        'generic_failure',
      );
      expect(defaultReport.errorCode, equals('generic_failure'));
      expect(defaultReport.errorMessage, isNull);
      expect(defaultReport.diagnostics['errorCode'], equals('generic_failure'));
    });

    test('unsupported factory returns typed unsupported report', () {
      final report = VGPassthroughRemuxExecutionReport.unsupported();

      expect(report.success, isFalse);
      expect(report.isFailure, isTrue);
      expect(report.errorCode, equals('unsupported_platform'));
      expect(
        report.errorMessage,
        equals('vanguard_media_engine plugin is not available'),
      );
      expect(report.proofBoundary, equals('unsupported'));
      expect(report.proofBoundaryMatches, isFalse);
      expect(report.diagnosticNonClaimsHold, isTrue);
      expect(report.diagnostics['errorCode'], equals('unsupported_platform'));
    });

    test('failure() and unsupported() omit sidecar fields from toMap()', () {
      final failureReport = VGPassthroughRemuxExecutionReport.failure(
        'OUTPUT_EXISTS',
        'Output exists',
      );
      final failureMap = failureReport.toMap();
      expect(failureReport.exportRoiSidecarPath, isNull);
      expect(failureReport.roiSidecarPath, isNull);
      expect(failureMap.containsKey('exportRoiSidecarPath'), isFalse);
      expect(failureMap.containsKey('roiSidecarPath'), isFalse);

      final unsupportedReport = VGPassthroughRemuxExecutionReport.unsupported();
      final unsupportedMap = unsupportedReport.toMap();
      expect(unsupportedReport.exportRoiSidecarPath, isNull);
      expect(unsupportedReport.roiSidecarPath, isNull);
      expect(unsupportedMap.containsKey('exportRoiSidecarPath'), isFalse);
      expect(unsupportedMap.containsKey('roiSidecarPath'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 3. VGPassthroughRemuxClient MethodChannel Contract
  // ---------------------------------------------------------------------------
  group('VGPassthroughRemuxClient', () {
    test(
      'export dispatches exact method and args and parses valid response',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'exportPassthroughRemux') {
            return <Object?, Object?>{
              'success': true,
              'path': call.arguments['outputPath'],
              'outputPath': call.arguments['outputPath'],
              'sourcePath': call.arguments['sourcePath'],
              'width': 1920,
              'height': 1080,
              'rotationDegrees': 0,
              'durationSeconds': 5.0,
              'videoSamples': 150,
              'audioSamples': 230,
              'outputSizeBytes': 2048576,
              'hasAudioTrack': true,
              'exportRoiSidecarPath': '/storage/output.roi.json',
              'roiSidecarPath': '/storage/output.roi.json',
              'proofBoundary':
                  'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
              'nonClaims': <Object?, Object?>{
                'mediaCodecAllocated': false,
                'productionExportTimelineBypass': false,
                'cppPassthroughRemuxSinkNode': false,
                'connectAppTouched': false,
              },
              'diagnosticHoldBeforeRemuxMs':
                  call.arguments['diagnosticHoldBeforeRemuxMs'],
            };
          }
          return null;
        });

        final client = VGPassthroughRemuxClient(channel: channel);
        const request = VGPassthroughRemuxRequest(
          sourcePath: ' /storage/input.mov ',
          outputPath: ' /storage/output.mp4 ',
          diagnosticHoldBeforeRemuxMs: 1200,
        );
        final report = await client.export(request);

        expect(recordedCall, isNotNull);
        expect(recordedCall!.method, equals('exportPassthroughRemux'));
        expect(
          recordedCall!.arguments,
          equals(<String, Object>{
            'sourcePath': '/storage/input.mov',
            'outputPath': '/storage/output.mp4',
            'diagnosticHoldBeforeRemuxMs': 1200,
          }),
        );

        expect(report.success, isTrue);
        expect(report.outputPath, equals('/storage/output.mp4'));
        expect(report.sourcePath, equals('/storage/input.mov'));
        expect(report.videoSamples, equals(150));
        expect(report.audioSamples, equals(230));
        expect(report.exportRoiSidecarPath, equals('/storage/output.roi.json'));
        expect(report.roiSidecarPath, equals('/storage/output.roi.json'));
        expect(report.outputWritten, isTrue);
        expect(report.proofBoundaryMatches, isTrue);
        expect(report.diagnosticNonClaimsHold, isTrue);
        expect(report.diagnosticHoldBeforeRemuxMs, equals(1200));
      },
    );

    test(
      'VGPassthroughRemuxClient.export method-channel mock with success sidecar fields returns a report with matching sidecar fields',
      () async {
        const expectedSidecar = '/data/user/0/cache/lane1.roi.json';
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'exportPassthroughRemux') {
            return <Object?, Object?>{
              'success': true,
              'path': call.arguments['outputPath'],
              'outputPath': call.arguments['outputPath'],
              'sourcePath': call.arguments['sourcePath'],
              'outputSizeBytes': 1024,
              'exportRoiSidecarPath': expectedSidecar,
              'roiSidecarPath': expectedSidecar,
              'proofBoundary':
                  'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
              'nonClaims': <Object?, Object?>{
                'mediaCodecAllocated': false,
                'productionExportTimelineBypass': false,
                'cppPassthroughRemuxSinkNode': false,
                'connectAppTouched': false,
              },
            };
          }
          return null;
        });

        final client = VGPassthroughRemuxClient(channel: channel);
        final report = await client.export(
          const VGPassthroughRemuxRequest(
            sourcePath: '/data/user/0/cache/input.mov',
            outputPath: '/data/user/0/cache/lane1.mp4',
          ),
        );

        expect(report.success, isTrue);
        expect(report.exportRoiSidecarPath, equals(expectedSidecar));
        expect(report.roiSidecarPath, equals(expectedSidecar));
        final map = report.toMap();
        expect(map['exportRoiSidecarPath'], equals(expectedSidecar));
        expect(map['roiSidecarPath'], equals(expectedSidecar));
      },
    );

    test(
      'blank sourcePath returns typed failure without calling MethodChannel',
      () async {
        var channelCalled = false;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          channelCalled = true;
          return null;
        });

        final client = VGPassthroughRemuxClient(channel: channel);
        const request = VGPassthroughRemuxRequest(
          sourcePath: '   \t  ',
          outputPath: '/storage/output.mp4',
        );
        final report = await client.export(request);

        expect(report.success, isFalse);
        expect(report.errorCode, equals('source_path_empty'));
        expect(report.proofBoundary, equals('client_failure'));
        expect(channelCalled, isFalse);
      },
    );

    test(
      'blank outputPath returns typed failure without calling MethodChannel',
      () async {
        var channelCalled = false;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          channelCalled = true;
          return null;
        });

        final client = VGPassthroughRemuxClient(channel: channel);
        const request = VGPassthroughRemuxRequest(
          sourcePath: '/storage/input.mov',
          outputPath: '   \n  ',
        );
        final report = await client.export(request);

        expect(report.success, isFalse);
        expect(report.errorCode, equals('output_path_empty'));
        expect(report.proofBoundary, equals('client_failure'));
        expect(channelCalled, isFalse);
      },
    );

    test('non-map response returns typed invalid_response failure', () async {
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'exportPassthroughRemux') {
          return 'unexpected_string_payload';
        }
        return null;
      });

      final client = VGPassthroughRemuxClient(channel: channel);
      const request = VGPassthroughRemuxRequest(
        sourcePath: '/in.mov',
        outputPath: '/out.mp4',
      );
      final report = await client.export(request);

      expect(report.success, isFalse);
      expect(report.errorCode, equals('invalid_response'));
      expect(report.errorMessage, contains('String'));
      expect(report.proofBoundary, equals('client_failure'));
    });

    test(
      'MissingPluginException returns unsupported_platform report',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw MissingPluginException('Plugin missing on platform');
        });

        final client = VGPassthroughRemuxClient(channel: channel);
        const request = VGPassthroughRemuxRequest(
          sourcePath: '/in.mov',
          outputPath: '/out.mp4',
        );
        final report = await client.export(request);

        expect(report.success, isFalse);
        expect(report.errorCode, equals('unsupported_platform'));
        expect(report.proofBoundary, equals('unsupported'));
      },
    );

    test(
      'PlatformException(code: OUTPUT_EXISTS, message: sentinel) maps into failure report with errorCode/errorMessage',
      () async {
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'OUTPUT_EXISTS',
            message: 'sentinel',
            details: <String, Object?>{'path': '/out.mp4'},
          );
        });

        final client = VGPassthroughRemuxClient(channel: channel);
        const request = VGPassthroughRemuxRequest(
          sourcePath: '/in.mov',
          outputPath: '/out.mp4',
        );
        final report = await client.export(request);

        expect(report.success, isFalse);
        expect(report.errorCode, equals('OUTPUT_EXISTS'));
        expect(report.errorMessage, equals('sentinel'));
        expect(report.proofBoundary, equals('client_failure'));
        expect(report.diagnostics['details'], isNotNull);
      },
    );

    test(
      'static exportFile convenience helper uses exact channel contract',
      () async {
        MethodCall? recordedCall;
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          recordedCall = call;
          if (call.method == 'exportPassthroughRemux') {
            return <Object?, Object?>{
              'success': true,
              'path': call.arguments['outputPath'],
              'outputPath': call.arguments['outputPath'],
              'sourcePath': call.arguments['sourcePath'],
              'outputSizeBytes': 512,
              'proofBoundary':
                  'native_passthrough_remux_execution_session_no_codec_no_exporttimeline_bypass',
              'nonClaims': <Object?, Object?>{
                'mediaCodecAllocated': false,
                'productionExportTimelineBypass': false,
                'cppPassthroughRemuxSinkNode': false,
                'connectAppTouched': false,
              },
            };
          }
          return null;
        });

        final report = await VGPassthroughRemuxClient.exportFile(
          sourcePath: '/static/in.mov',
          outputPath: '/static/out.mp4',
          diagnosticHoldBeforeRemuxMs: 500,
          channel: channel,
        );

        expect(recordedCall, isNotNull);
        expect(recordedCall!.method, equals('exportPassthroughRemux'));
        expect(
          recordedCall!.arguments,
          equals(<String, Object>{
            'sourcePath': '/static/in.mov',
            'outputPath': '/static/out.mp4',
            'diagnosticHoldBeforeRemuxMs': 500,
          }),
        );

        expect(report.success, isTrue);
        expect(report.outputWritten, isTrue);
        expect(report.proofBoundaryMatches, isTrue);
      },
    );
  });
}
