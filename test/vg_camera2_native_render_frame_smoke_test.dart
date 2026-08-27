// vg_camera2_native_render_frame_smoke_test.dart
// vanguard_media_engine — Phase 3-Unit K: Android Camera2 PRIVATE ImageReader
// HardwareBuffer native-render frame smoke foundation Dart model & MethodChannel contract tests.

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
  'nativeSessionCreated': true,
  'nativeSessionDestroyed': true,
  'nativeRenderAttempted': true,
  'nativeRenderPassed': true,
  'nativeRenderRaw': 'status=PASS;durationMs=12;renderedFrames=1;',
  'outputSurfaceReleased': true,
  'surfaceTextureReleased': true,
  'decision': 'nativeRenderPassed',
  'reasons': const <String>[],
  'events': const [
    'openCameraRequested',
    'onOpened',
    'createCaptureSessionRequested',
    'onConfigured',
    'repeatingRequestStarted',
    'onImageAvailable',
    'nativeRenderAttempted',
    'onSessionClosed',
    'onDeviceClosed',
  ],
  'diagnostics': const {'testKey': 'testVal'},
  'durationMs': 240,
  if (overrides != null) ...overrides,
};

VGCamera2NativeRenderFrameSmokeReport _createSampleReport([
  Map<String, Object?>? overrides,
]) => VGCamera2NativeRenderFrameSmokeReport.fromMap(
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

  group('VGCamera2NativeRenderFrameSmokeDecision enum & fromRaw', () {
    test('enum has exact expected 18 values in order', () {
      expect(
        VGCamera2NativeRenderFrameSmokeDecision.values,
        orderedEquals(const [
          VGCamera2NativeRenderFrameSmokeDecision.nativeRenderPassed,
          VGCamera2NativeRenderFrameSmokeDecision.apiUnsupported,
          VGCamera2NativeRenderFrameSmokeDecision.nativeSessionFailed,
          VGCamera2NativeRenderFrameSmokeDecision.permissionRequired,
          VGCamera2NativeRenderFrameSmokeDecision.noCamera,
          VGCamera2NativeRenderFrameSmokeDecision.cameraManagerUnavailable,
          VGCamera2NativeRenderFrameSmokeDecision.cameraUnavailable,
          VGCamera2NativeRenderFrameSmokeDecision.unsupportedStream,
          VGCamera2NativeRenderFrameSmokeDecision.hardwareBufferUnavailable,
          VGCamera2NativeRenderFrameSmokeDecision.openDisconnected,
          VGCamera2NativeRenderFrameSmokeDecision.openError,
          VGCamera2NativeRenderFrameSmokeDecision.openTimeout,
          VGCamera2NativeRenderFrameSmokeDecision.sessionConfigureFailed,
          VGCamera2NativeRenderFrameSmokeDecision.sessionConfigureTimeout,
          VGCamera2NativeRenderFrameSmokeDecision.repeatingRequestFailed,
          VGCamera2NativeRenderFrameSmokeDecision.frameTimeout,
          VGCamera2NativeRenderFrameSmokeDecision.nativeRenderFailed,
          VGCamera2NativeRenderFrameSmokeDecision.captureFailed,
        ]),
      );
      expect(VGCamera2NativeRenderFrameSmokeDecision.values.length, equals(18));
    });

    test('fromRaw maps all known valid decision strings', () {
      for (final value in VGCamera2NativeRenderFrameSmokeDecision.values) {
        expect(
          VGCamera2NativeRenderFrameSmokeDecision.fromRaw(value.name),
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
            VGCamera2NativeRenderFrameSmokeDecision.fromRaw(invalid),
            equals(VGCamera2NativeRenderFrameSmokeDecision.captureFailed),
          );
        }
      },
    );
  });

  group('VGCamera2NativeRenderFrameSmokeReport fromMap and toMap', () {
    test(
      'nativeRenderPassed decision report parses and round-trips all fields cleanly',
      () {
        final report = VGCamera2NativeRenderFrameSmokeReport.fromMap(
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
        expect(report.nativeSessionCreated, isTrue);
        expect(report.nativeSessionDestroyed, isTrue);
        expect(report.nativeRenderAttempted, isTrue);
        expect(report.nativeRenderPassed, isTrue);
        expect(
          report.nativeRenderRaw,
          equals('status=PASS;durationMs=12;renderedFrames=1;'),
        );
        expect(report.outputSurfaceReleased, isTrue);
        expect(report.surfaceTextureReleased, isTrue);
        expect(
          report.decision,
          equals(VGCamera2NativeRenderFrameSmokeDecision.nativeRenderPassed),
        );
        expect(report.reasons, isEmpty);
        expect(report.events.length, equals(9));
        expect(report.diagnostics, equals({'testKey': 'testVal'}));
        expect(report.durationMs, equals(240));

        expect(report.isPermissionRequired, isFalse);
        expect(report.isNativeRenderPassed, isTrue);
        expect(report.isAttempted, isTrue);
        expect(report.isCleanedUp, isTrue);

        final serialized = report.toMap();
        expect(serialized['success'], isTrue);
        expect(serialized['hardwareBufferWidth'], equals(640));
        expect(serialized['hardwareBufferFormat'], equals(34));
        expect(serialized['syncFenceAwaited'], isTrue);
        expect(serialized['syncFenceClosed'], isTrue);
        expect(serialized['nativeSessionCreated'], isTrue);
        expect(serialized['nativeSessionDestroyed'], isTrue);
        expect(serialized['nativeRenderAttempted'], isTrue);
        expect(serialized['nativeRenderPassed'], isTrue);
        expect(
          serialized['nativeRenderRaw'],
          equals('status=PASS;durationMs=12;renderedFrames=1;'),
        );
        expect(serialized['outputSurfaceReleased'], isTrue);
        expect(serialized['surfaceTextureReleased'], isTrue);
        expect(serialized['decision'], equals('nativeRenderPassed'));
        expect(serialized['events'], equals(report.events));
        expect(serialized['diagnostics'], equals(report.diagnostics));

        final roundTrip = VGCamera2NativeRenderFrameSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('lifecycle failure decisions parse coherently', () {
      void check(
        VGCamera2NativeRenderFrameSmokeDecision d,
        List<String> r, {
        bool att = true,
        bool cln = true,
        Map<String, Object?> ov = const {},
      }) {
        final report = VGCamera2NativeRenderFrameSmokeReport.fromMap(
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
            'nativeSessionCreated': att,
            'nativeSessionDestroyed': cln,
            'nativeRenderAttempted': att,
            'nativeRenderPassed': false,
            'outputSurfaceReleased': cln,
            'surfaceTextureReleased': cln,
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
        VGCamera2NativeRenderFrameSmokeDecision.apiUnsupported,
        const ['api_below_29'],
        att: false,
        cln: false,
        ov: const {
          'apiLevel': 28,
          'cameraId': null,
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'nativeRenderAttempted': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.nativeSessionFailed,
        const ['native_session_create_failed'],
        att: false,
        cln: false,
        ov: const {
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'nativeRenderAttempted': false,
          'diagnostics': {'nativeCreateResult': 'status=ERROR;'},
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.permissionRequired,
        const ['camera_permission_absent'],
        att: false,
        cln: false,
        ov: const {
          'hasCameraPermission': false,
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'nativeRenderAttempted': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.noCamera,
        const ['no_camera_available'],
        att: false,
        cln: false,
        ov: const {
          'cameraId': null,
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'nativeRenderAttempted': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.cameraManagerUnavailable,
        const ['camera_manager_unavailable'],
        att: false,
        cln: false,
        ov: const {
          'cameraId': null,
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'nativeRenderAttempted': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.cameraUnavailable,
        const ['requested_camera_id_not_found'],
        att: false,
        cln: false,
        ov: const {
          'cameraId': '99',
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'nativeRenderAttempted': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.unsupportedStream,
        const ['no_private_output_sizes'],
        att: false,
        cln: false,
        ov: const {
          'nativeSessionCreated': false,
          'nativeSessionDestroyed': false,
          'nativeRenderAttempted': false,
          'outputSurfaceReleased': false,
          'surfaceTextureReleased': false,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.hardwareBufferUnavailable,
        const ['hardware_buffer_unavailable'],
        ov: const {
          'hardwareBufferAvailable': false,
          'hardwareBufferClosed': false,
          'nativeRenderAttempted': false,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.openDisconnected,
        const ['camera_disconnected'],
        cln: false,
        ov: const {
          'opened': false,
          'sessionClosed': false,
          'nativeRenderAttempted': false,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.openError,
        const ['camera_open_error'],
        cln: false,
        ov: const {
          'opened': false,
          'sessionClosed': false,
          'nativeRenderAttempted': false,
          'diagnostics': {'errorCode': 3},
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.openTimeout,
        const ['camera_open_timeout'],
        cln: false,
        ov: const {
          'opened': false,
          'sessionClosed': false,
          'deviceClosed': false,
          'nativeRenderAttempted': false,
          'durationMs': 8002,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.sessionConfigureFailed,
        const ['session_configure_failed'],
        cln: false,
        ov: const {
          'sessionConfigured': false,
          'sessionClosed': false,
          'nativeRenderAttempted': false,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.sessionConfigureTimeout,
        const ['session_configure_timeout'],
        cln: false,
        ov: const {
          'sessionConfigured': false,
          'sessionClosed': false,
          'nativeRenderAttempted': false,
          'durationMs': 8100,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.repeatingRequestFailed,
        const ['repeating_request_failed'],
        ov: const {
          'repeatingStarted': false,
          'nativeRenderAttempted': false,
          'diagnostics': {'setRepeatingRequestError': 'CameraAccessException'},
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.frameTimeout,
        const ['frame_timeout'],
        ov: const {
          'frameReceived': false,
          'nativeRenderAttempted': false,
          'durationMs': 8200,
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.nativeRenderFailed,
        const ['native_render_failed'],
        ov: const {
          'nativeRenderPassed': false,
          'nativeRenderRaw': 'status=FAIL;error=SHADER_COMPILATION_FAILED;',
          'diagnostics': {
            'nativeRenderResult':
                'status=FAIL;error=SHADER_COMPILATION_FAILED;',
          },
        },
      );
      check(
        VGCamera2NativeRenderFrameSmokeDecision.captureFailed,
        const ['capture_failed'],
        ov: const {
          'frameReceived': false,
          'nativeRenderAttempted': false,
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
          final report = VGCamera2NativeRenderFrameSmokeReport.fromMap(invalid);
          expect(report.success, isFalse);
          expect(report.apiLevel, equals(0));
          expect(report.cameraId, isNull);
          expect(report.selectedLensFacing, equals('unknown'));
          expect(report.imageFormatName, equals('PRIVATE'));
          expect(
            report.decision,
            equals(VGCamera2NativeRenderFrameSmokeDecision.captureFailed),
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
        final report = VGCamera2NativeRenderFrameSmokeReport.fromMap({
          for (final key in _createSampleRawMap().keys) key: null,
        });
        expect(
          report,
          equals(
            const VGCamera2NativeRenderFrameSmokeReport(
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
              nativeSessionCreated: false,
              nativeSessionDestroyed: false,
              nativeRenderAttempted: false,
              nativeRenderPassed: false,
              nativeRenderRaw: null,
              outputSurfaceReleased: false,
              surfaceTextureReleased: false,
              decision: VGCamera2NativeRenderFrameSmokeDecision.captureFailed,
              reasons: [],
              events: [],
              diagnostics: {},
              durationMs: 0,
            ),
          ),
        );

        final parsed = VGCamera2NativeRenderFrameSmokeReport.fromMap({
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

        final parsedBad = VGCamera2NativeRenderFrameSmokeReport.fromMap(
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

  group('VGCamera2NativeRenderFrameSmokeReport getters', () {
    test('isPermissionRequired reflects decision strictly', () {
      expect(
        _createSampleReport({
          'decision': 'permissionRequired',
        }).isPermissionRequired,
        isTrue,
      );
      expect(
        _createSampleReport({
          'decision': 'nativeRenderPassed',
        }).isPermissionRequired,
        isFalse,
      );
    });

    test('isNativeRenderPassed reflects decision strictly', () {
      expect(
        _createSampleReport({
          'decision': 'nativeRenderPassed',
        }).isNativeRenderPassed,
        isTrue,
      );
      expect(
        _createSampleReport({
          'decision': 'nativeRenderFailed',
        }).isNativeRenderPassed,
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
      'isCleanedUp requires sessionClosed && deviceClosed && imageReaderClosed && nativeSessionDestroyed && outputSurfaceReleased && surfaceTextureReleased',
      () {
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isTrue,
        );
        expect(
          _createSampleReport({
            'sessionClosed': false,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': false,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': false,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': false,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': false,
            'surfaceTextureReleased': true,
          }).isCleanedUp,
          isFalse,
        );
        expect(
          _createSampleReport({
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'nativeSessionDestroyed': true,
            'outputSurfaceReleased': true,
            'surfaceTextureReleased': false,
          }).isCleanedUp,
          isFalse,
        );
      },
    );
  });

  group('VGCamera2NativeRenderFrameSmokeReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      final a = _createSampleReport();
      final b = _createSampleReport();

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      for (final snippet in [
        'VGCamera2NativeRenderFrameSmokeReport(',
        'decision: VGCamera2NativeRenderFrameSmokeDecision.nativeRenderPassed',
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
        'nativeSessionCreated: true',
        'nativeSessionDestroyed: true',
        'nativeRenderAttempted: true',
        'nativeRenderPassed: true',
        'nativeRenderRaw: status=PASS;',
        'outputSurfaceReleased: true',
        'surfaceTextureReleased: true',
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
        {'nativeSessionCreated': false},
        {'nativeSessionDestroyed': false},
        {'nativeRenderAttempted': false},
        {'nativeRenderPassed': false},
        {'nativeRenderRaw': 'status=FAIL;'},
        {'outputSurfaceReleased': false},
        {'surfaceTextureReleased': false},
        {'decision': 'nativeRenderFailed'},
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
    'VGCamera2NativeRenderFrameSmokeReport.runAndroidCamera2NativeRenderFrameSmoke MethodChannel contract',
    () {
      Future<MethodCall> captureCall({
        required Future<VGCamera2NativeRenderFrameSmokeReport> Function(
          MethodChannel channel,
        )
        action,
        Map<String, Object?>? response,
      }) async {
        MethodCall? capturedCall;
        const channel = MethodChannel('test_vanguard_native_render_contract');
        binaryMessenger.setMockMethodCallHandler(channel, (call) async {
          capturedCall = call;
          return response ?? _createSampleRawMap();
        });
        await action(channel);
        return capturedCall!;
      }

      test(
        'invokes runAndroidDagPhase3UnitKCameraNativeRenderSmoke with default args and omits null cameraId',
        () async {
          final call = await captureCall(
            action: (channel) =>
                VGCamera2NativeRenderFrameSmokeReport.runAndroidCamera2NativeRenderFrameSmoke(
                  channel: channel,
                ),
          );

          expect(
            call.method,
            equals('runAndroidDagPhase3UnitKCameraNativeRenderSmoke'),
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
                VGCamera2NativeRenderFrameSmokeReport.runAndroidCamera2NativeRenderFrameSmoke(
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
            equals('runAndroidDagPhase3UnitKCameraNativeRenderSmoke'),
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
              VGCamera2NativeRenderFrameSmokeReport.runAndroidCamera2NativeRenderFrameSmoke(
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
            await VGCamera2NativeRenderFrameSmokeReport.runAndroidCamera2NativeRenderFrameSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase3UnitKCameraNativeRenderSmoke'),
        );
        expect(report.success, isTrue);
      });
    },
  );
}
