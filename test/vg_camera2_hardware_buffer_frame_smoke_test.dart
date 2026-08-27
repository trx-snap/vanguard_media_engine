// vg_camera2_hardware_buffer_frame_smoke_test.dart
// vanguard_media_engine — Phase 3-Unit J: Android Camera2 single-camera
// PRIVATE ImageReader HardwareBuffer frame smoke foundation Dart model & MethodChannel contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

Map<String, Object?> _createSampleRawMap([Map<String, Object?>? overrides]) => {
  'success': true,
  'apiLevel': 34,
  'hasCameraPermission': true,
  'attemptedOpen': true,
  'opened': true,
  'sessionConfigured': true,
  'repeatingStarted': true,
  'frameReceived': true,
  'hardwareBufferAvailable': true,
  'hardwareBufferClosed': true,
  'imageClosed': true,
  'sessionClosed': true,
  'deviceClosed': true,
  'imageReaderClosed': true,
  'cameraId': '0',
  'selectedLensFacing': 'back',
  'selectedWidth': 640,
  'selectedHeight': 480,
  'imageFormatName': 'PRIVATE',
  'frameTimestampNs': 1234567890123,
  'hardwareBufferWidth': 640,
  'hardwareBufferHeight': 480,
  'hardwareBufferFormat': 34,
  'hardwareBufferLayers': 1,
  'hardwareBufferUsage': 256,
  'syncFenceAwaited': true,
  'syncFenceClosed': true,
  'decision': 'frameCaptured',
  'reasons': const <String>[],
  'events': const [
    'openCameraRequested',
    'onOpened',
    'createCaptureSessionRequested',
    'onConfigured',
    'repeatingRequestStarted',
    'onImageAvailable',
    'hardwareBufferAcquired',
    'hardwareBufferClosed',
    'imageClosed',
    'onSessionClosed',
    'onDeviceClosed',
  ],
  'diagnostics': const {'testKey': 'testVal'},
  'durationMs': 240,
  if (overrides != null) ...overrides,
};

VGCamera2HardwareBufferFrameSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGCamera2HardwareBufferFrameSmokeReport.fromMap(
  _createSampleRawMap(overrides),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  group('VGCamera2HardwareBufferFrameSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 16 values in order', () {
      expect(
        VGCamera2HardwareBufferFrameSmokeDecision.values,
        orderedEquals(const [
          VGCamera2HardwareBufferFrameSmokeDecision.frameCaptured,
          VGCamera2HardwareBufferFrameSmokeDecision.apiUnsupported,
          VGCamera2HardwareBufferFrameSmokeDecision.permissionRequired,
          VGCamera2HardwareBufferFrameSmokeDecision.noCamera,
          VGCamera2HardwareBufferFrameSmokeDecision.cameraManagerUnavailable,
          VGCamera2HardwareBufferFrameSmokeDecision.cameraUnavailable,
          VGCamera2HardwareBufferFrameSmokeDecision.unsupportedStream,
          VGCamera2HardwareBufferFrameSmokeDecision.hardwareBufferUnavailable,
          VGCamera2HardwareBufferFrameSmokeDecision.openDisconnected,
          VGCamera2HardwareBufferFrameSmokeDecision.openError,
          VGCamera2HardwareBufferFrameSmokeDecision.openTimeout,
          VGCamera2HardwareBufferFrameSmokeDecision.sessionConfigureFailed,
          VGCamera2HardwareBufferFrameSmokeDecision.sessionConfigureTimeout,
          VGCamera2HardwareBufferFrameSmokeDecision.repeatingRequestFailed,
          VGCamera2HardwareBufferFrameSmokeDecision.frameTimeout,
          VGCamera2HardwareBufferFrameSmokeDecision.captureFailed,
        ]),
      );
      expect(
        VGCamera2HardwareBufferFrameSmokeDecision.values.length,
        equals(16),
      );
    });

    test('fromRaw maps all known valid decision strings', () {
      for (final value in VGCamera2HardwareBufferFrameSmokeDecision.values) {
        expect(
          VGCamera2HardwareBufferFrameSmokeDecision.fromRaw(value.name),
          equals(value),
        );
      }
    });

    test(
      'fromRaw falls back to captureFailed for unknown, non-string, or null values',
      () {
        const invalidValues = <Object?>[
          'unknownDecision',
          '',
          null,
          123,
          3.14,
          true,
          <String>[],
          <String, Object?>{},
        ];
        for (final invalid in invalidValues) {
          expect(
            VGCamera2HardwareBufferFrameSmokeDecision.fromRaw(invalid),
            equals(VGCamera2HardwareBufferFrameSmokeDecision.captureFailed),
          );
        }
      },
    );
  });

  group('VGCamera2HardwareBufferFrameSmokeReport fromMap and toMap', () {
    test(
      'frameCaptured decision report parses and round-trips all fields cleanly',
      () {
        final report = VGCamera2HardwareBufferFrameSmokeReport.fromMap(
          _createSampleRawMap(),
        );

        expect(report.success, isTrue);
        expect(report.apiLevel, equals(34));
        expect(report.hasCameraPermission, isTrue);
        expect(report.attemptedOpen, isTrue);
        expect(report.opened, isTrue);
        expect(report.sessionConfigured, isTrue);
        expect(report.repeatingStarted, isTrue);
        expect(report.frameReceived, isTrue);
        expect(report.hardwareBufferAvailable, isTrue);
        expect(report.hardwareBufferClosed, isTrue);
        expect(report.imageClosed, isTrue);
        expect(report.sessionClosed, isTrue);
        expect(report.deviceClosed, isTrue);
        expect(report.imageReaderClosed, isTrue);
        expect(report.cameraId, equals('0'));
        expect(report.selectedLensFacing, equals('back'));
        expect(report.selectedWidth, equals(640));
        expect(report.selectedHeight, equals(480));
        expect(report.imageFormatName, equals('PRIVATE'));
        expect(report.frameTimestampNs, equals(1234567890123));
        expect(report.hardwareBufferWidth, equals(640));
        expect(report.hardwareBufferHeight, equals(480));
        expect(report.hardwareBufferFormat, equals(34));
        expect(report.hardwareBufferLayers, equals(1));
        expect(report.hardwareBufferUsage, equals(256));
        expect(report.syncFenceAwaited, isTrue);
        expect(report.syncFenceClosed, isTrue);
        expect(
          report.decision,
          equals(VGCamera2HardwareBufferFrameSmokeDecision.frameCaptured),
        );
        expect(report.reasons, isEmpty);
        expect(report.events.length, equals(11));
        expect(report.diagnostics, equals({'testKey': 'testVal'}));
        expect(report.durationMs, equals(240));

        expect(report.isPermissionRequired, isFalse);
        expect(report.isFrameCaptured, isTrue);
        expect(report.isAttempted, isTrue);
        expect(report.isCleanedUp, isTrue);

        final serialized = report.toMap();
        expect(serialized['success'], isTrue);
        expect(serialized['hardwareBufferWidth'], equals(640));
        expect(serialized['hardwareBufferFormat'], equals(34));
        expect(serialized['syncFenceAwaited'], isTrue);
        expect(serialized['syncFenceClosed'], isTrue);
        expect(serialized['decision'], equals('frameCaptured'));
        expect(serialized['events'], equals(report.events));
        expect(serialized['diagnostics'], equals(report.diagnostics));

        final roundTrip = VGCamera2HardwareBufferFrameSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('lifecycle failure decisions parse coherently', () {
      void check(
        VGCamera2HardwareBufferFrameSmokeDecision d,
        List<String> r, {
        bool att = true,
        bool cln = true,
        Map<String, Object?> ov = const {},
      }) {
        final report = VGCamera2HardwareBufferFrameSmokeReport.fromMap(
          _createSampleRawMap({
            'success': false,
            'attemptedOpen': att,
            'opened': att,
            'sessionConfigured': att,
            'repeatingStarted': att,
            'frameReceived': att,
            'hardwareBufferAvailable': att,
            'hardwareBufferClosed': att,
            'imageClosed': att,
            'sessionClosed': cln,
            'deviceClosed': cln,
            'imageReaderClosed': cln,
            'decision': d.name,
            'reasons': r,
            ...ov,
          }),
        );
        expect(report.decision, equals(d));
        expect(report.reasons, equals(r));
        expect(report.isAttempted, equals(att));
        expect(report.isCleanedUp, equals(cln));
      }

      check(
        VGCamera2HardwareBufferFrameSmokeDecision.apiUnsupported,
        const ['api_level_below_29'],
        att: false,
        cln: false,
        ov: const {'apiLevel': 28, 'cameraId': null},
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.permissionRequired,
        const ['camera_permission_absent'],
        att: false,
        cln: false,
        ov: const {'hasCameraPermission': false},
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.noCamera,
        const ['no_camera_available'],
        att: false,
        cln: false,
        ov: const {'cameraId': null},
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.cameraManagerUnavailable,
        const ['camera_manager_unavailable'],
        att: false,
        cln: false,
        ov: const {'cameraId': null},
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.cameraUnavailable,
        const ['requested_camera_id_not_found'],
        att: false,
        cln: false,
        ov: const {'cameraId': '99'},
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.unsupportedStream,
        const ['no_supported_private_stream_sizes'],
        att: false,
        cln: false,
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.hardwareBufferUnavailable,
        const ['image_get_hardware_buffer_returned_null'],
        ov: const {
          'hardwareBufferAvailable': false,
          'hardwareBufferClosed': false,
        },
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.openDisconnected,
        const ['camera_disconnected'],
        cln: false,
        ov: const {'opened': false, 'sessionClosed': false},
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.openError,
        const ['camera_open_error'],
        cln: false,
        ov: const {
          'opened': false,
          'sessionClosed': false,
          'diagnostics': {'errorCode': 3},
        },
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.openTimeout,
        const ['camera_open_timeout'],
        cln: false,
        ov: const {
          'opened': false,
          'sessionClosed': false,
          'deviceClosed': false,
          'durationMs': 8002,
        },
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.sessionConfigureFailed,
        const ['session_configure_failed'],
        cln: false,
        ov: const {'sessionConfigured': false, 'sessionClosed': false},
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.sessionConfigureTimeout,
        const ['session_configure_timeout'],
        cln: false,
        ov: const {
          'sessionConfigured': false,
          'sessionClosed': false,
          'durationMs': 8100,
        },
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.repeatingRequestFailed,
        const ['repeating_request_failed'],
        ov: const {
          'repeatingStarted': false,
          'diagnostics': {'setRepeatingRequestError': 'CameraAccessException'},
        },
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.frameTimeout,
        const ['frame_timeout'],
        ov: const {'frameReceived': false, 'durationMs': 8200},
      );
      check(
        VGCamera2HardwareBufferFrameSmokeDecision.captureFailed,
        const ['capture_failed'],
        ov: const {
          'frameReceived': false,
          'diagnostics': {'captureFailureReason': 1},
          'durationMs': 300,
        },
      );
    });

    test(
      'fromMap handles malformed non-map inputs by preserving raw in diagnostics and using reason native_result_not_a_map',
      () {
        for (final invalid in [
          null,
          'not_a_map',
          999,
          <Object?>['a', 'b'],
        ]) {
          final report = VGCamera2HardwareBufferFrameSmokeReport.fromMap(
            invalid,
          );
          expect(report.success, isFalse);
          expect(report.apiLevel, equals(0));
          expect(report.cameraId, isNull);
          expect(report.selectedLensFacing, equals('unknown'));
          expect(report.imageFormatName, equals('PRIVATE'));
          expect(
            report.decision,
            equals(VGCamera2HardwareBufferFrameSmokeDecision.captureFailed),
          );
          expect(
            report.reasons,
            equals(const <String>['native_result_not_a_map']),
          );
          expect(report.events, isEmpty);
          expect(report.diagnostics, equals(<String, Object?>{'raw': invalid}));
          expect(report.durationMs, equals(0));
        }
      },
    );

    test(
      'fromMap handles missing/malformed list/map fields defensively producing safe defaults',
      () {
        final report = VGCamera2HardwareBufferFrameSmokeReport.fromMap({
          for (final key in _createSampleRawMap().keys) key: null,
        });
        expect(
          report,
          equals(
            const VGCamera2HardwareBufferFrameSmokeReport(
              success: false,
              apiLevel: 0,
              hasCameraPermission: false,
              attemptedOpen: false,
              opened: false,
              sessionConfigured: false,
              repeatingStarted: false,
              frameReceived: false,
              hardwareBufferAvailable: false,
              hardwareBufferClosed: false,
              imageClosed: false,
              sessionClosed: false,
              deviceClosed: false,
              imageReaderClosed: false,
              cameraId: null,
              selectedLensFacing: 'unknown',
              selectedWidth: 0,
              selectedHeight: 0,
              imageFormatName: 'PRIVATE',
              frameTimestampNs: null,
              hardwareBufferWidth: null,
              hardwareBufferHeight: null,
              hardwareBufferFormat: null,
              hardwareBufferLayers: null,
              hardwareBufferUsage: null,
              syncFenceAwaited: false,
              syncFenceClosed: false,
              decision: VGCamera2HardwareBufferFrameSmokeDecision.captureFailed,
              reasons: [],
              events: [],
              diagnostics: {},
              durationMs: 0,
            ),
          ),
        );

        final parsed = VGCamera2HardwareBufferFrameSmokeReport.fromMap({
          'success': true,
          'apiLevel': 34.0,
          'selectedWidth': 640.0,
          'selectedHeight': 480.0,
          'frameTimestampNs': 987654321.0,
          'hardwareBufferWidth': 640.0,
          'hardwareBufferHeight': 480.0,
          'hardwareBufferFormat': 34.0,
          'hardwareBufferLayers': 1.0,
          'hardwareBufferUsage': 256.0,
          'durationMs': 150.0,
          'reasons': <Object?>['r1', 123, null],
          'events': <Object?>['e1', 456],
          'diagnostics': <Object?, Object?>{'nested': 'ok'},
        });
        expect(parsed.apiLevel, equals(34));
        expect(parsed.selectedWidth, equals(640));
        expect(parsed.selectedHeight, equals(480));
        expect(parsed.frameTimestampNs, equals(987654321));
        expect(parsed.hardwareBufferWidth, equals(640));
        expect(parsed.hardwareBufferHeight, equals(480));
        expect(parsed.hardwareBufferFormat, equals(34));
        expect(parsed.hardwareBufferLayers, equals(1));
        expect(parsed.hardwareBufferUsage, equals(256));
        expect(parsed.durationMs, equals(150));
        expect(parsed.reasons, equals(['r1', '123']));
        expect(parsed.events, equals(['e1', '456']));
        expect(parsed.diagnostics, equals({'nested': 'ok'}));

        final parsedBad = VGCamera2HardwareBufferFrameSmokeReport.fromMap(
          <Object?, Object?>{
            'reasons': 'not_a_list',
            'events': 12345,
            'diagnostics': 'not_a_map',
          },
        );
        expect(parsedBad.reasons, isEmpty);
        expect(parsedBad.events, isEmpty);
        expect(parsedBad.diagnostics, isEmpty);
      },
    );
  });

  group('VGCamera2HardwareBufferFrameSmokeReport getters', () {
    test('isPermissionRequired reflects decision strictly', () {
      expect(
        _createSampleReport({
          'decision': 'permissionRequired',
        }).isPermissionRequired,
        isTrue,
      );
      expect(
        _createSampleReport({'decision': 'frameCaptured'}).isPermissionRequired,
        isFalse,
      );
    });

    test('isFrameCaptured reflects decision strictly', () {
      expect(
        _createSampleReport({'decision': 'frameCaptured'}).isFrameCaptured,
        isTrue,
      );
      expect(
        _createSampleReport({'decision': 'captureFailed'}).isFrameCaptured,
        isFalse,
      );
    });

    test('isAttempted mirrors attemptedOpen exactly', () {
      expect(_createSampleReport({'attemptedOpen': true}).isAttempted, isTrue);
      expect(
        _createSampleReport({'attemptedOpen': false}).isAttempted,
        isFalse,
      );
    });

    test(
      'isCleanedUp requires sessionClosed && deviceClosed && imageReaderClosed',
      () {
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
          }).isCleanedUp,
          isTrue,
        );
        expect(
          _createSampleReport({
            'sessionClosed': false,
            'deviceClosed': true,
            'imageReaderClosed': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': false,
            'imageReaderClosed': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': false,
          }).isCleanedUp,
          isFalse,
        );
      },
    );
  });

  group('VGCamera2HardwareBufferFrameSmokeReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      for (final snippet in [
        'VGCamera2HardwareBufferFrameSmokeReport(',
        'decision: VGCamera2HardwareBufferFrameSmokeDecision.frameCaptured',
        'success: true',
        'apiLevel: 34',
        'cameraId: 0',
        'selectedWidth: 640',
        'selectedHeight: 480',
        'hardwareBufferWidth: 640',
        'hardwareBufferHeight: 480',
        'hardwareBufferFormat: 34',
        'hardwareBufferLayers: 1',
        'hardwareBufferUsage: 256',
        'syncFenceAwaited: true',
        'syncFenceClosed: true',
        'frameTimestampNs: 1234567890123',
        'durationMs: 240',
      ]) {
        expect(a.toString(), contains(snippet));
      }
    });

    test(
      'stable diagnostics hash produces equal hash and equality with different map key order',
      () {
        final report1 = _createSampleReport({
          'diagnostics': {'alpha': 1, 'beta': 2, 'gamma': 3},
        });
        final report2 = _createSampleReport({
          'diagnostics': {'gamma': 3, 'alpha': 1, 'beta': 2},
        });

        expect(report1, equals(report2));
        expect(report1.hashCode, equals(report2.hashCode));
      },
    );

    test('inequality when any single field differs', () {
      final base = _createSampleReport();
      const diffs = <Map<String, Object?>>[
        {'success': false},
        {'apiLevel': 33},
        {'hasCameraPermission': false},
        {'attemptedOpen': false},
        {'opened': false},
        {'sessionConfigured': false},
        {'repeatingStarted': false},
        {'frameReceived': false},
        {'hardwareBufferAvailable': false},
        {'hardwareBufferClosed': false},
        {'imageClosed': false},
        {'sessionClosed': false},
        {'deviceClosed': false},
        {'imageReaderClosed': false},
        {'cameraId': '1'},
        {'selectedLensFacing': 'front'},
        {'selectedWidth': 1280},
        {'selectedHeight': 720},
        {'imageFormatName': 'YUV_420_888'},
        {'frameTimestampNs': 2000},
        {'hardwareBufferWidth': 1280},
        {'hardwareBufferHeight': 720},
        {'hardwareBufferFormat': 1},
        {'hardwareBufferLayers': 2},
        {'hardwareBufferUsage': 512},
        {'syncFenceAwaited': false},
        {'syncFenceClosed': false},
        {'decision': 'captureFailed'},
        {
          'reasons': ['other_reason'],
        },
        {
          'events': ['other_event'],
        },
        {
          'diagnostics': {'other': 1},
        },
        {'durationMs': 999},
      ];

      for (final diff in diffs) {
        final variant = _createSampleReport(diff);
        expect(base, isNot(equals(variant)));
        expect(base.hashCode, isNot(equals(variant.hashCode)));
      }
    });
  });

  group(
    'VGCamera2HardwareBufferFrameSmokeReport.runAndroidCamera2HardwareBufferFrameSmoke MethodChannel contract',
    () {
      Future<MethodCall> captureCall({
        required Future<VGCamera2HardwareBufferFrameSmokeReport> Function(
          MethodChannel channel,
        )
        action,
        Map<String, Object?>? response,
      }) async {
        MethodCall? capturedCall;
        const channel = MethodChannel('test_vanguard_smoke_contract');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return response ?? _createSampleRawMap();
        });
        await action(channel);
        return capturedCall!;
      }

      test(
        'invokes runAndroidDagPhase3UnitJHardwareBufferFrameSmoke with default args and omits null cameraId',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2HardwareBufferFrameSmokeReport.runAndroidCamera2HardwareBufferFrameSmoke(
                  channel: channel,
                ),
          );

          expect(
            call.method,
            equals('runAndroidDagPhase3UnitJHardwareBufferFrameSmoke'),
          );
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments.containsKey('cameraId'), isFalse);
          expect(arguments['timeoutMs'], equals(8000));
          expect(arguments['maxWidth'], equals(640));
          expect(arguments['maxHeight'], equals(480));
        },
      );

      test(
        'passes explicit nonblank cameraId, custom timeout, and custom dimensions',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2HardwareBufferFrameSmokeReport.runAndroidCamera2HardwareBufferFrameSmoke(
                  cameraId: '1',
                  timeout: const Duration(seconds: 12),
                  maxWidth: 1280,
                  maxHeight: 720,
                  channel: channel,
                ),
            response: _createSampleRawMap({
              'cameraId': '1',
              'selectedLensFacing': 'front',
              'selectedWidth': 1280,
              'selectedHeight': 720,
            }),
          );

          expect(
            call.method,
            equals('runAndroidDagPhase3UnitJHardwareBufferFrameSmoke'),
          );
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['cameraId'], equals('1'));
          expect(arguments['timeoutMs'], equals(12000));
          expect(arguments['maxWidth'], equals(1280));
          expect(arguments['maxHeight'], equals(720));
        },
      );

      test('omits blank or whitespace-only cameraId', () async {
        final call = await captureCall(
          action: (channel) =>
              VGCamera2HardwareBufferFrameSmokeReport.runAndroidCamera2HardwareBufferFrameSmoke(
                cameraId: '   ',
                channel: channel,
              ),
        );

        final arguments = call.arguments as Map<Object?, Object?>;
        expect(arguments.containsKey('cameraId'), isFalse);
        expect(arguments['timeoutMs'], equals(8000));
        expect(arguments['maxWidth'], equals(640));
        expect(arguments['maxHeight'], equals(480));
      });

      test('uses default vanguard_media_engine channel when omitted', () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return _createSampleRawMap({'durationMs': 160});
        });

        final report =
            await VGCamera2HardwareBufferFrameSmokeReport.runAndroidCamera2HardwareBufferFrameSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase3UnitJHardwareBufferFrameSmoke'),
        );
        expect(report.success, isTrue);
      });
    },
  );
}
