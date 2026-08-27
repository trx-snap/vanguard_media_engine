// vg_camera2_image_reader_frame_smoke_test.dart
// vanguard_media_engine — Phase 3-Unit I: Android Camera2 single-camera
// ImageReader frame smoke foundation Dart model & MethodChannel contract tests.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const defaultChannel = MethodChannel('vanguard_media_engine');

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(defaultChannel, null);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 1. VGCamera2ImageReaderFrameSmokeDecision Enum and fromRaw Verification
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ImageReaderFrameSmokeDecision enum & fromRaw', () {
    test('enum has exact expected values in order', () {
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.values,
        orderedEquals(<VGCamera2ImageReaderFrameSmokeDecision>[
          VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
          VGCamera2ImageReaderFrameSmokeDecision.permissionRequired,
          VGCamera2ImageReaderFrameSmokeDecision.noCamera,
          VGCamera2ImageReaderFrameSmokeDecision.cameraManagerUnavailable,
          VGCamera2ImageReaderFrameSmokeDecision.cameraUnavailable,
          VGCamera2ImageReaderFrameSmokeDecision.unsupportedStream,
          VGCamera2ImageReaderFrameSmokeDecision.openDisconnected,
          VGCamera2ImageReaderFrameSmokeDecision.openError,
          VGCamera2ImageReaderFrameSmokeDecision.openTimeout,
          VGCamera2ImageReaderFrameSmokeDecision.sessionConfigureFailed,
          VGCamera2ImageReaderFrameSmokeDecision.sessionConfigureTimeout,
          VGCamera2ImageReaderFrameSmokeDecision.repeatingRequestFailed,
          VGCamera2ImageReaderFrameSmokeDecision.frameTimeout,
          VGCamera2ImageReaderFrameSmokeDecision.captureFailed,
        ]),
      );
      expect(VGCamera2ImageReaderFrameSmokeDecision.values.length, equals(14));
    });

    test('fromRaw maps known valid decision strings', () {
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw('frameCaptured'),
        equals(VGCamera2ImageReaderFrameSmokeDecision.frameCaptured),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw('permissionRequired'),
        equals(VGCamera2ImageReaderFrameSmokeDecision.permissionRequired),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw('noCamera'),
        equals(VGCamera2ImageReaderFrameSmokeDecision.noCamera),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw(
          'cameraManagerUnavailable',
        ),
        equals(VGCamera2ImageReaderFrameSmokeDecision.cameraManagerUnavailable),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw('cameraUnavailable'),
        equals(VGCamera2ImageReaderFrameSmokeDecision.cameraUnavailable),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw('unsupportedStream'),
        equals(VGCamera2ImageReaderFrameSmokeDecision.unsupportedStream),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw('openDisconnected'),
        equals(VGCamera2ImageReaderFrameSmokeDecision.openDisconnected),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw('openError'),
        equals(VGCamera2ImageReaderFrameSmokeDecision.openError),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw('openTimeout'),
        equals(VGCamera2ImageReaderFrameSmokeDecision.openTimeout),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw(
          'sessionConfigureFailed',
        ),
        equals(VGCamera2ImageReaderFrameSmokeDecision.sessionConfigureFailed),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw(
          'sessionConfigureTimeout',
        ),
        equals(VGCamera2ImageReaderFrameSmokeDecision.sessionConfigureTimeout),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw(
          'repeatingRequestFailed',
        ),
        equals(VGCamera2ImageReaderFrameSmokeDecision.repeatingRequestFailed),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw('frameTimeout'),
        equals(VGCamera2ImageReaderFrameSmokeDecision.frameTimeout),
      );
      expect(
        VGCamera2ImageReaderFrameSmokeDecision.fromRaw('captureFailed'),
        equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
      );
    });

    test(
      'fromRaw falls back to captureFailed for unknown, non-string, or null values',
      () {
        expect(
          VGCamera2ImageReaderFrameSmokeDecision.fromRaw('unknownDecision'),
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
        expect(
          VGCamera2ImageReaderFrameSmokeDecision.fromRaw(''),
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
        expect(
          VGCamera2ImageReaderFrameSmokeDecision.fromRaw(null),
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
        expect(
          VGCamera2ImageReaderFrameSmokeDecision.fromRaw(123),
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
        expect(
          VGCamera2ImageReaderFrameSmokeDecision.fromRaw(3.14),
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
        expect(
          VGCamera2ImageReaderFrameSmokeDecision.fromRaw(true),
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
        expect(
          VGCamera2ImageReaderFrameSmokeDecision.fromRaw(const <String>[]),
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
        expect(
          VGCamera2ImageReaderFrameSmokeDecision.fromRaw(
            const <String, Object?>{},
          ),
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGCamera2ImageReaderFrameSmokeReport fromMap and toMap
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ImageReaderFrameSmokeReport fromMap and toMap', () {
    test(
      'frameCaptured decision report parses and serializes all fields cleanly',
      () {
        final rawMap = <String, Object?>{
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': true,
          'attemptedOpen': true,
          'opened': true,
          'sessionConfigured': true,
          'repeatingStarted': true,
          'frameReceived': true,
          'imageClosed': true,
          'sessionClosed': true,
          'deviceClosed': true,
          'imageReaderClosed': true,
          'cameraId': '0',
          'selectedLensFacing': 'back',
          'selectedWidth': 640,
          'selectedHeight': 480,
          'imageFormatName': 'YUV_420_888',
          'frameTimestampNs': 1234567890123,
          'framePlaneCount': 3,
          'decision': 'frameCaptured',
          'reasons': <String>[],
          'events': <String>[
            'openCameraRequested',
            'onOpened',
            'createCaptureSessionRequested',
            'onConfigured',
            'repeatingRequestStarted',
            'onImageAvailable',
            'onSessionClosed',
            'onDeviceClosed',
          ],
          'diagnostics': <String, Object?>{'testKey': 'testVal'},
          'durationMs': 240,
        };

        final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
        expect(report.success, isTrue);
        expect(report.apiLevel, equals(34));
        expect(report.hasCameraPermission, isTrue);
        expect(report.attemptedOpen, isTrue);
        expect(report.opened, isTrue);
        expect(report.sessionConfigured, isTrue);
        expect(report.repeatingStarted, isTrue);
        expect(report.frameReceived, isTrue);
        expect(report.imageClosed, isTrue);
        expect(report.sessionClosed, isTrue);
        expect(report.deviceClosed, isTrue);
        expect(report.imageReaderClosed, isTrue);
        expect(report.cameraId, equals('0'));
        expect(report.selectedLensFacing, equals('back'));
        expect(report.selectedWidth, equals(640));
        expect(report.selectedHeight, equals(480));
        expect(report.imageFormatName, equals('YUV_420_888'));
        expect(report.frameTimestampNs, equals(1234567890123));
        expect(report.framePlaneCount, equals(3));
        expect(
          report.decision,
          equals(VGCamera2ImageReaderFrameSmokeDecision.frameCaptured),
        );
        expect(report.reasons, isEmpty);
        expect(
          report.events,
          equals(<String>[
            'openCameraRequested',
            'onOpened',
            'createCaptureSessionRequested',
            'onConfigured',
            'repeatingRequestStarted',
            'onImageAvailable',
            'onSessionClosed',
            'onDeviceClosed',
          ]),
        );
        expect(report.diagnostics, equals({'testKey': 'testVal'}));
        expect(report.durationMs, equals(240));

        expect(report.isPermissionRequired, isFalse);
        expect(report.isFrameCaptured, isTrue);
        expect(report.isAttempted, isTrue);
        expect(report.isCleanedUp, isTrue);

        final serialized = report.toMap();
        expect(serialized['success'], isTrue);
        expect(serialized['apiLevel'], equals(34));
        expect(serialized['hasCameraPermission'], isTrue);
        expect(serialized['attemptedOpen'], isTrue);
        expect(serialized['opened'], isTrue);
        expect(serialized['sessionConfigured'], isTrue);
        expect(serialized['repeatingStarted'], isTrue);
        expect(serialized['frameReceived'], isTrue);
        expect(serialized['imageClosed'], isTrue);
        expect(serialized['sessionClosed'], isTrue);
        expect(serialized['deviceClosed'], isTrue);
        expect(serialized['imageReaderClosed'], isTrue);
        expect(serialized['cameraId'], equals('0'));
        expect(serialized['selectedLensFacing'], equals('back'));
        expect(serialized['selectedWidth'], equals(640));
        expect(serialized['selectedHeight'], equals(480));
        expect(serialized['imageFormatName'], equals('YUV_420_888'));
        expect(serialized['frameTimestampNs'], equals(1234567890123));
        expect(serialized['framePlaneCount'], equals(3));
        expect(serialized['decision'], equals('frameCaptured'));
        expect(serialized['reasons'], isEmpty);
        expect(
          serialized['events'],
          equals(<String>[
            'openCameraRequested',
            'onOpened',
            'createCaptureSessionRequested',
            'onConfigured',
            'repeatingRequestStarted',
            'onImageAvailable',
            'onSessionClosed',
            'onDeviceClosed',
          ]),
        );
        expect(serialized['diagnostics'], equals({'testKey': 'testVal'}));
        expect(serialized['durationMs'], equals(240));

        final roundTrip = VGCamera2ImageReaderFrameSmokeReport.fromMap(
          serialized,
        );
        expect(roundTrip, equals(report));
      },
    );

    test('permissionRequired decision parses and serializes cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': false,
        'attemptedOpen': false,
        'opened': false,
        'sessionConfigured': false,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': false,
        'deviceClosed': false,
        'imageReaderClosed': false,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'selectedWidth': 0,
        'selectedHeight': 0,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'permissionRequired',
        'reasons': <String>['camera_permission_absent'],
        'events': <String>[],
        'diagnostics': <String, Object?>{},
        'durationMs': 5,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(report.success, isFalse);
      expect(report.apiLevel, equals(34));
      expect(report.hasCameraPermission, isFalse);
      expect(report.attemptedOpen, isFalse);
      expect(report.opened, isFalse);
      expect(report.sessionConfigured, isFalse);
      expect(report.repeatingStarted, isFalse);
      expect(report.frameReceived, isFalse);
      expect(report.imageClosed, isFalse);
      expect(report.sessionClosed, isFalse);
      expect(report.deviceClosed, isFalse);
      expect(report.imageReaderClosed, isFalse);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.permissionRequired),
      );
      expect(report.reasons, equals(['camera_permission_absent']));
      expect(report.events, isEmpty);
      expect(report.diagnostics, isEmpty);
      expect(report.durationMs, equals(5));

      expect(report.isPermissionRequired, isTrue);
      expect(report.isFrameCaptured, isFalse);
      expect(report.isAttempted, isFalse);
      expect(report.isCleanedUp, isFalse);

      final serialized = report.toMap();
      expect(serialized['decision'], equals('permissionRequired'));
      expect(
        VGCamera2ImageReaderFrameSmokeReport.fromMap(serialized),
        equals(report),
      );
    });

    test('noCamera decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 33,
        'hasCameraPermission': true,
        'attemptedOpen': false,
        'opened': false,
        'sessionConfigured': false,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': false,
        'deviceClosed': false,
        'imageReaderClosed': false,
        'cameraId': null,
        'selectedLensFacing': 'unknown',
        'selectedWidth': 0,
        'selectedHeight': 0,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'noCamera',
        'reasons': <String>['no_camera_available'],
        'events': <String>[],
        'diagnostics': <String, Object?>{},
        'durationMs': 3,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.noCamera),
      );
      expect(report.cameraId, isNull);
      expect(report.selectedLensFacing, equals('unknown'));
      expect(report.reasons, equals(['no_camera_available']));
    });

    test('cameraManagerUnavailable decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 33,
        'hasCameraPermission': true,
        'attemptedOpen': false,
        'opened': false,
        'sessionConfigured': false,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': false,
        'deviceClosed': false,
        'imageReaderClosed': false,
        'cameraId': null,
        'selectedLensFacing': 'unknown',
        'selectedWidth': 0,
        'selectedHeight': 0,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'cameraManagerUnavailable',
        'reasons': <String>['camera_manager_unavailable'],
        'events': <String>[],
        'diagnostics': <String, Object?>{},
        'durationMs': 2,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.cameraManagerUnavailable),
      );
      expect(report.reasons, equals(['camera_manager_unavailable']));
    });

    test('cameraUnavailable decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': false,
        'opened': false,
        'sessionConfigured': false,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': false,
        'deviceClosed': false,
        'imageReaderClosed': false,
        'cameraId': '99',
        'selectedLensFacing': 'unknown',
        'selectedWidth': 0,
        'selectedHeight': 0,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'cameraUnavailable',
        'reasons': <String>['requested_camera_id_not_found'],
        'events': <String>[],
        'diagnostics': <String, Object?>{},
        'durationMs': 4,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.cameraUnavailable),
      );
      expect(report.cameraId, equals('99'));
      expect(report.reasons, equals(['requested_camera_id_not_found']));
    });

    test('unsupportedStream decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': false,
        'opened': false,
        'sessionConfigured': false,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': false,
        'deviceClosed': false,
        'imageReaderClosed': false,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'selectedWidth': 0,
        'selectedHeight': 0,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'unsupportedStream',
        'reasons': <String>['no_yuv_420_888_output_sizes'],
        'events': <String>[],
        'diagnostics': <String, Object?>{},
        'durationMs': 12,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.unsupportedStream),
      );
      expect(report.reasons, equals(['no_yuv_420_888_output_sizes']));
    });

    test('openDisconnected decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': true,
        'opened': false,
        'sessionConfigured': false,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': false,
        'deviceClosed': true,
        'imageReaderClosed': true,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'selectedWidth': 640,
        'selectedHeight': 480,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'openDisconnected',
        'reasons': <String>['camera_disconnected'],
        'events': <String>['openCameraRequested', 'onDisconnected'],
        'diagnostics': <String, Object?>{},
        'durationMs': 50,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.openDisconnected),
      );
      expect(report.attemptedOpen, isTrue);
      expect(report.opened, isFalse);
      expect(report.events, equals(['openCameraRequested', 'onDisconnected']));
    });

    test('openError decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': true,
        'opened': false,
        'sessionConfigured': false,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': false,
        'deviceClosed': true,
        'imageReaderClosed': true,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'selectedWidth': 640,
        'selectedHeight': 480,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'openError',
        'reasons': <String>['camera_open_error'],
        'events': <String>['openCameraRequested', 'onError:3'],
        'diagnostics': <String, Object?>{'errorCode': 3},
        'durationMs': 60,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.openError),
      );
      expect(report.diagnostics['errorCode'], equals(3));
    });

    test('openTimeout decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': true,
        'opened': false,
        'sessionConfigured': false,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': false,
        'deviceClosed': false,
        'imageReaderClosed': true,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'selectedWidth': 640,
        'selectedHeight': 480,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'openTimeout',
        'reasons': <String>['camera_open_timeout'],
        'events': <String>['openCameraRequested', 'openTimeout'],
        'diagnostics': <String, Object?>{},
        'durationMs': 8002,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.openTimeout),
      );
      expect(report.reasons, equals(['camera_open_timeout']));
      expect(report.durationMs, equals(8002));
    });

    test('sessionConfigureFailed decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': true,
        'opened': true,
        'sessionConfigured': false,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': false,
        'deviceClosed': true,
        'imageReaderClosed': true,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'selectedWidth': 640,
        'selectedHeight': 480,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'sessionConfigureFailed',
        'reasons': <String>['session_configure_failed'],
        'events': <String>[
          'openCameraRequested',
          'onOpened',
          'createCaptureSessionRequested',
          'onConfigureFailed',
        ],
        'diagnostics': <String, Object?>{},
        'durationMs': 150,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.sessionConfigureFailed),
      );
      expect(report.reasons, equals(['session_configure_failed']));
      expect(report.opened, isTrue);
      expect(report.sessionConfigured, isFalse);
    });

    test('sessionConfigureTimeout decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': true,
        'opened': true,
        'sessionConfigured': false,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': false,
        'deviceClosed': true,
        'imageReaderClosed': true,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'selectedWidth': 640,
        'selectedHeight': 480,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'sessionConfigureTimeout',
        'reasons': <String>['session_configure_timeout'],
        'events': <String>[
          'openCameraRequested',
          'onOpened',
          'createCaptureSessionRequested',
          'sessionConfigureTimeout',
        ],
        'diagnostics': <String, Object?>{},
        'durationMs': 8100,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.sessionConfigureTimeout),
      );
      expect(report.reasons, equals(['session_configure_timeout']));
      expect(report.opened, isTrue);
    });

    test('repeatingRequestFailed decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': true,
        'opened': true,
        'sessionConfigured': true,
        'repeatingStarted': false,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': true,
        'deviceClosed': true,
        'imageReaderClosed': true,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'selectedWidth': 640,
        'selectedHeight': 480,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'repeatingRequestFailed',
        'reasons': <String>['repeating_request_failed'],
        'events': <String>[
          'openCameraRequested',
          'onOpened',
          'createCaptureSessionRequested',
          'onConfigured',
        ],
        'diagnostics': <String, Object?>{
          'setRepeatingRequestError': 'CameraAccessException',
        },
        'durationMs': 200,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.repeatingRequestFailed),
      );
      expect(report.reasons, equals(['repeating_request_failed']));
      expect(report.sessionConfigured, isTrue);
      expect(report.repeatingStarted, isFalse);
    });

    test('frameTimeout decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': true,
        'opened': true,
        'sessionConfigured': true,
        'repeatingStarted': true,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': true,
        'deviceClosed': true,
        'imageReaderClosed': true,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'selectedWidth': 640,
        'selectedHeight': 480,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'frameTimeout',
        'reasons': <String>['frame_timeout'],
        'events': <String>[
          'openCameraRequested',
          'onOpened',
          'createCaptureSessionRequested',
          'onConfigured',
          'repeatingRequestStarted',
          'frameTimeout',
        ],
        'diagnostics': <String, Object?>{},
        'durationMs': 8200,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.frameTimeout),
      );
      expect(report.reasons, equals(['frame_timeout']));
      expect(report.repeatingStarted, isTrue);
      expect(report.frameReceived, isFalse);
    });

    test('captureFailed decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': true,
        'opened': true,
        'sessionConfigured': true,
        'repeatingStarted': true,
        'frameReceived': false,
        'imageClosed': false,
        'sessionClosed': true,
        'deviceClosed': true,
        'imageReaderClosed': true,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'selectedWidth': 640,
        'selectedHeight': 480,
        'imageFormatName': 'YUV_420_888',
        'frameTimestampNs': null,
        'framePlaneCount': null,
        'decision': 'captureFailed',
        'reasons': <String>['capture_failed'],
        'events': <String>[
          'openCameraRequested',
          'onOpened',
          'createCaptureSessionRequested',
          'onConfigured',
          'repeatingRequestStarted',
          'onCaptureFailed',
        ],
        'diagnostics': <String, Object?>{'captureFailureReason': 1},
        'durationMs': 300,
      };

      final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
      );
      expect(report.reasons, equals(['capture_failed']));
      expect(report.diagnostics['captureFailureReason'], equals(1));
    });

    test(
      'fromMap handles malformed non-map inputs by preserving raw in diagnostics and using reason native_result_not_a_map',
      () {
        final nullReport = VGCamera2ImageReaderFrameSmokeReport.fromMap(null);
        expect(nullReport.success, isFalse);
        expect(nullReport.apiLevel, equals(0));
        expect(nullReport.hasCameraPermission, isFalse);
        expect(nullReport.attemptedOpen, isFalse);
        expect(nullReport.opened, isFalse);
        expect(nullReport.sessionConfigured, isFalse);
        expect(nullReport.repeatingStarted, isFalse);
        expect(nullReport.frameReceived, isFalse);
        expect(nullReport.imageClosed, isFalse);
        expect(nullReport.sessionClosed, isFalse);
        expect(nullReport.deviceClosed, isFalse);
        expect(nullReport.imageReaderClosed, isFalse);
        expect(nullReport.cameraId, isNull);
        expect(nullReport.selectedLensFacing, equals('unknown'));
        expect(nullReport.selectedWidth, equals(0));
        expect(nullReport.selectedHeight, equals(0));
        expect(nullReport.imageFormatName, equals('YUV_420_888'));
        expect(nullReport.frameTimestampNs, isNull);
        expect(nullReport.framePlaneCount, isNull);
        expect(
          nullReport.decision,
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
        expect(nullReport.reasons, equals(['native_result_not_a_map']));
        expect(nullReport.events, isEmpty);
        expect(nullReport.diagnostics, equals({'raw': null}));
        expect(nullReport.durationMs, equals(0));

        final strReport = VGCamera2ImageReaderFrameSmokeReport.fromMap(
          'not_a_map',
        );
        expect(strReport.success, isFalse);
        expect(
          strReport.decision,
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
        expect(strReport.reasons, equals(['native_result_not_a_map']));
        expect(strReport.diagnostics, equals({'raw': 'not_a_map'}));

        final numReport = VGCamera2ImageReaderFrameSmokeReport.fromMap(999);
        expect(numReport.success, isFalse);
        expect(numReport.diagnostics, equals({'raw': 999}));

        final listReport = VGCamera2ImageReaderFrameSmokeReport.fromMap(
          <Object?>['a', 'b'],
        );
        expect(listReport.success, isFalse);
        expect(
          listReport.diagnostics,
          equals({
            'raw': ['a', 'b'],
          }),
        );
      },
    );

    test(
      'fromMap handles missing/malformed list/map fields defensively producing safe defaults',
      () {
        final mapWithNulls = <Object?, Object?>{
          'success': null,
          'apiLevel': null,
          'hasCameraPermission': null,
          'attemptedOpen': null,
          'opened': null,
          'sessionConfigured': null,
          'repeatingStarted': null,
          'frameReceived': null,
          'imageClosed': null,
          'sessionClosed': null,
          'deviceClosed': null,
          'imageReaderClosed': null,
          'cameraId': null,
          'selectedLensFacing': null,
          'selectedWidth': null,
          'selectedHeight': null,
          'imageFormatName': null,
          'frameTimestampNs': null,
          'framePlaneCount': null,
          'decision': null,
          'reasons': null,
          'events': null,
          'diagnostics': null,
          'durationMs': null,
        };

        final report = VGCamera2ImageReaderFrameSmokeReport.fromMap(
          mapWithNulls,
        );
        expect(report.success, isFalse);
        expect(report.apiLevel, equals(0));
        expect(report.hasCameraPermission, isFalse);
        expect(report.attemptedOpen, isFalse);
        expect(report.opened, isFalse);
        expect(report.sessionConfigured, isFalse);
        expect(report.repeatingStarted, isFalse);
        expect(report.frameReceived, isFalse);
        expect(report.imageClosed, isFalse);
        expect(report.sessionClosed, isFalse);
        expect(report.deviceClosed, isFalse);
        expect(report.imageReaderClosed, isFalse);
        expect(report.cameraId, isNull);
        expect(report.selectedLensFacing, equals('unknown'));
        expect(report.selectedWidth, equals(0));
        expect(report.selectedHeight, equals(0));
        expect(report.imageFormatName, equals('YUV_420_888'));
        expect(report.frameTimestampNs, isNull);
        expect(report.framePlaneCount, isNull);
        expect(
          report.decision,
          equals(VGCamera2ImageReaderFrameSmokeDecision.captureFailed),
        );
        expect(report.reasons, isEmpty);
        expect(report.events, isEmpty);
        expect(report.diagnostics, isEmpty);
        expect(report.durationMs, equals(0));

        // Map with doubles / mixed list elements
        final mapWithMixed = <Object?, Object?>{
          'success': true,
          'apiLevel': 34.0,
          'selectedWidth': 640.0,
          'selectedHeight': 480.0,
          'frameTimestampNs': 987654321.0,
          'framePlaneCount': 3.0,
          'durationMs': 150.0,
          'reasons': <Object?>['r1', 123, null],
          'events': <Object?>['e1', 456],
          'diagnostics': <Object?, Object?>{'nested': 'ok'},
        };

        final parsed = VGCamera2ImageReaderFrameSmokeReport.fromMap(
          mapWithMixed,
        );
        expect(parsed.apiLevel, equals(34));
        expect(parsed.selectedWidth, equals(640));
        expect(parsed.selectedHeight, equals(480));
        expect(parsed.frameTimestampNs, equals(987654321));
        expect(parsed.framePlaneCount, equals(3));
        expect(parsed.durationMs, equals(150));
        expect(parsed.reasons, equals(['r1', '123']));
        expect(parsed.events, equals(['e1', '456']));
        expect(parsed.diagnostics, equals({'nested': 'ok'}));

        // Non-list reasons and events, non-map diagnostics
        final mapWithBadTypes = <Object?, Object?>{
          'reasons': 'not_a_list',
          'events': 12345,
          'diagnostics': 'not_a_map',
        };
        final parsedBad = VGCamera2ImageReaderFrameSmokeReport.fromMap(
          mapWithBadTypes,
        );
        expect(parsedBad.reasons, isEmpty);
        expect(parsedBad.events, isEmpty);
        expect(parsedBad.diagnostics, isEmpty);
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 3. Getters Logic
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ImageReaderFrameSmokeReport getters', () {
    test('isPermissionRequired reflects decision strictly', () {
      const permReport = VGCamera2ImageReaderFrameSmokeReport(
        success: false,
        apiLevel: 34,
        hasCameraPermission: false,
        attemptedOpen: false,
        opened: false,
        sessionConfigured: false,
        repeatingStarted: false,
        frameReceived: false,
        imageClosed: false,
        sessionClosed: false,
        deviceClosed: false,
        imageReaderClosed: false,
        cameraId: '0',
        selectedLensFacing: 'back',
        selectedWidth: 0,
        selectedHeight: 0,
        imageFormatName: 'YUV_420_888',
        frameTimestampNs: null,
        framePlaneCount: null,
        decision: VGCamera2ImageReaderFrameSmokeDecision.permissionRequired,
        reasons: <String>['camera_permission_absent'],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 5,
      );
      expect(permReport.isPermissionRequired, isTrue);

      const okReport = VGCamera2ImageReaderFrameSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        sessionConfigured: true,
        repeatingStarted: true,
        frameReceived: true,
        imageClosed: true,
        sessionClosed: true,
        deviceClosed: true,
        imageReaderClosed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        selectedWidth: 640,
        selectedHeight: 480,
        imageFormatName: 'YUV_420_888',
        frameTimestampNs: 100,
        framePlaneCount: 3,
        decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
        reasons: <String>[],
        events: <String>['onOpened', 'onConfigured', 'onImageAvailable'],
        diagnostics: <String, Object?>{},
        durationMs: 100,
      );
      expect(okReport.isPermissionRequired, isFalse);
    });

    test('isFrameCaptured reflects decision strictly', () {
      const okReport = VGCamera2ImageReaderFrameSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        sessionConfigured: true,
        repeatingStarted: true,
        frameReceived: true,
        imageClosed: true,
        sessionClosed: true,
        deviceClosed: true,
        imageReaderClosed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        selectedWidth: 640,
        selectedHeight: 480,
        imageFormatName: 'YUV_420_888',
        frameTimestampNs: 100,
        framePlaneCount: 3,
        decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
        reasons: <String>[],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 100,
      );
      expect(okReport.isFrameCaptured, isTrue);

      const failedReport = VGCamera2ImageReaderFrameSmokeReport(
        success: false,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        sessionConfigured: true,
        repeatingStarted: true,
        frameReceived: false,
        imageClosed: false,
        sessionClosed: true,
        deviceClosed: true,
        imageReaderClosed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        selectedWidth: 640,
        selectedHeight: 480,
        imageFormatName: 'YUV_420_888',
        frameTimestampNs: null,
        framePlaneCount: null,
        decision: VGCamera2ImageReaderFrameSmokeDecision.frameTimeout,
        reasons: <String>[],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 100,
      );
      expect(failedReport.isFrameCaptured, isFalse);
    });

    test('isAttempted mirrors attemptedOpen exactly', () {
      const attempted = VGCamera2ImageReaderFrameSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        sessionConfigured: true,
        repeatingStarted: true,
        frameReceived: true,
        imageClosed: true,
        sessionClosed: true,
        deviceClosed: true,
        imageReaderClosed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        selectedWidth: 640,
        selectedHeight: 480,
        imageFormatName: 'YUV_420_888',
        frameTimestampNs: 100,
        framePlaneCount: 3,
        decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
        reasons: <String>[],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 100,
      );
      expect(attempted.isAttempted, isTrue);

      const notAttempted = VGCamera2ImageReaderFrameSmokeReport(
        success: false,
        apiLevel: 34,
        hasCameraPermission: false,
        attemptedOpen: false,
        opened: false,
        sessionConfigured: false,
        repeatingStarted: false,
        frameReceived: false,
        imageClosed: false,
        sessionClosed: false,
        deviceClosed: false,
        imageReaderClosed: false,
        cameraId: null,
        selectedLensFacing: 'unknown',
        selectedWidth: 0,
        selectedHeight: 0,
        imageFormatName: 'YUV_420_888',
        frameTimestampNs: null,
        framePlaneCount: null,
        decision: VGCamera2ImageReaderFrameSmokeDecision.permissionRequired,
        reasons: <String>[],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 0,
      );
      expect(notAttempted.isAttempted, isFalse);
    });

    test(
      'isCleanedUp requires sessionClosed && deviceClosed && imageReaderClosed',
      () {
        const cleanedUp = VGCamera2ImageReaderFrameSmokeReport(
          success: true,
          apiLevel: 34,
          hasCameraPermission: true,
          attemptedOpen: true,
          opened: true,
          sessionConfigured: true,
          repeatingStarted: true,
          frameReceived: true,
          imageClosed: true,
          sessionClosed: true,
          deviceClosed: true,
          imageReaderClosed: true,
          cameraId: '0',
          selectedLensFacing: 'back',
          selectedWidth: 640,
          selectedHeight: 480,
          imageFormatName: 'YUV_420_888',
          frameTimestampNs: 100,
          framePlaneCount: 3,
          decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
          reasons: <String>[],
          events: <String>[],
          diagnostics: <String, Object?>{},
          durationMs: 100,
        );
        expect(cleanedUp.isCleanedUp, isTrue);

        // Missing sessionClosed
        const noSessionClose = VGCamera2ImageReaderFrameSmokeReport(
          success: false,
          apiLevel: 34,
          hasCameraPermission: true,
          attemptedOpen: true,
          opened: true,
          sessionConfigured: true,
          repeatingStarted: true,
          frameReceived: true,
          imageClosed: true,
          sessionClosed: false,
          deviceClosed: true,
          imageReaderClosed: true,
          cameraId: '0',
          selectedLensFacing: 'back',
          selectedWidth: 640,
          selectedHeight: 480,
          imageFormatName: 'YUV_420_888',
          frameTimestampNs: 100,
          framePlaneCount: 3,
          decision: VGCamera2ImageReaderFrameSmokeDecision.captureFailed,
          reasons: <String>[],
          events: <String>[],
          diagnostics: <String, Object?>{},
          durationMs: 100,
        );
        expect(noSessionClose.isCleanedUp, isFalse);

        // Missing deviceClosed
        const noDeviceClose = VGCamera2ImageReaderFrameSmokeReport(
          success: false,
          apiLevel: 34,
          hasCameraPermission: true,
          attemptedOpen: true,
          opened: true,
          sessionConfigured: true,
          repeatingStarted: true,
          frameReceived: true,
          imageClosed: true,
          sessionClosed: true,
          deviceClosed: false,
          imageReaderClosed: true,
          cameraId: '0',
          selectedLensFacing: 'back',
          selectedWidth: 640,
          selectedHeight: 480,
          imageFormatName: 'YUV_420_888',
          frameTimestampNs: 100,
          framePlaneCount: 3,
          decision: VGCamera2ImageReaderFrameSmokeDecision.captureFailed,
          reasons: <String>[],
          events: <String>[],
          diagnostics: <String, Object?>{},
          durationMs: 100,
        );
        expect(noDeviceClose.isCleanedUp, isFalse);

        // Missing imageReaderClosed
        const noReaderClose = VGCamera2ImageReaderFrameSmokeReport(
          success: false,
          apiLevel: 34,
          hasCameraPermission: true,
          attemptedOpen: true,
          opened: true,
          sessionConfigured: true,
          repeatingStarted: true,
          frameReceived: true,
          imageClosed: true,
          sessionClosed: true,
          deviceClosed: true,
          imageReaderClosed: false,
          cameraId: '0',
          selectedLensFacing: 'back',
          selectedWidth: 640,
          selectedHeight: 480,
          imageFormatName: 'YUV_420_888',
          frameTimestampNs: 100,
          framePlaneCount: 3,
          decision: VGCamera2ImageReaderFrameSmokeDecision.captureFailed,
          reasons: <String>[],
          events: <String>[],
          diagnostics: <String, Object?>{},
          durationMs: 100,
        );
        expect(noReaderClose.isCleanedUp, isFalse);
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Equality, hashCode, toString, and Stable Diagnostics Hash
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2ImageReaderFrameSmokeReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      const a = VGCamera2ImageReaderFrameSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        sessionConfigured: true,
        repeatingStarted: true,
        frameReceived: true,
        imageClosed: true,
        sessionClosed: true,
        deviceClosed: true,
        imageReaderClosed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        selectedWidth: 640,
        selectedHeight: 480,
        imageFormatName: 'YUV_420_888',
        frameTimestampNs: 1000,
        framePlaneCount: 3,
        decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
        reasons: <String>['ok'],
        events: <String>['onOpened', 'onConfigured', 'onImageAvailable'],
        diagnostics: <String, Object?>{'k': 'v'},
        durationMs: 100,
      );

      const b = VGCamera2ImageReaderFrameSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        sessionConfigured: true,
        repeatingStarted: true,
        frameReceived: true,
        imageClosed: true,
        sessionClosed: true,
        deviceClosed: true,
        imageReaderClosed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        selectedWidth: 640,
        selectedHeight: 480,
        imageFormatName: 'YUV_420_888',
        frameTimestampNs: 1000,
        framePlaneCount: 3,
        decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
        reasons: <String>['ok'],
        events: <String>['onOpened', 'onConfigured', 'onImageAvailable'],
        diagnostics: <String, Object?>{'k': 'v'},
        durationMs: 100,
      );

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGCamera2ImageReaderFrameSmokeReport('));
      expect(
        a.toString(),
        contains(
          'decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured',
        ),
      );
      expect(a.toString(), contains('success: true'));
      expect(a.toString(), contains('apiLevel: 34'));
      expect(a.toString(), contains('cameraId: 0'));
      expect(a.toString(), contains('selectedWidth: 640'));
      expect(a.toString(), contains('selectedHeight: 480'));
      expect(a.toString(), contains('frameTimestampNs: 1000'));
      expect(a.toString(), contains('framePlaneCount: 3'));
      expect(a.toString(), contains('durationMs: 100'));
    });

    test(
      'stable diagnostics hash produces equal hash and equality with different map key order',
      () {
        final diag1 = <String, Object?>{'alpha': 1, 'beta': 2, 'gamma': 3};
        final diag2 = <String, Object?>{'gamma': 3, 'alpha': 1, 'beta': 2};

        final report1 = VGCamera2ImageReaderFrameSmokeReport(
          success: true,
          apiLevel: 34,
          hasCameraPermission: true,
          attemptedOpen: true,
          opened: true,
          sessionConfigured: true,
          repeatingStarted: true,
          frameReceived: true,
          imageClosed: true,
          sessionClosed: true,
          deviceClosed: true,
          imageReaderClosed: true,
          cameraId: '0',
          selectedLensFacing: 'back',
          selectedWidth: 640,
          selectedHeight: 480,
          imageFormatName: 'YUV_420_888',
          frameTimestampNs: 1000,
          framePlaneCount: 3,
          decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
          reasons: const <String>['r1'],
          events: const <String>['e1'],
          diagnostics: diag1,
          durationMs: 50,
        );

        final report2 = VGCamera2ImageReaderFrameSmokeReport(
          success: true,
          apiLevel: 34,
          hasCameraPermission: true,
          attemptedOpen: true,
          opened: true,
          sessionConfigured: true,
          repeatingStarted: true,
          frameReceived: true,
          imageClosed: true,
          sessionClosed: true,
          deviceClosed: true,
          imageReaderClosed: true,
          cameraId: '0',
          selectedLensFacing: 'back',
          selectedWidth: 640,
          selectedHeight: 480,
          imageFormatName: 'YUV_420_888',
          frameTimestampNs: 1000,
          framePlaneCount: 3,
          decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
          reasons: const <String>['r1'],
          events: const <String>['e1'],
          diagnostics: diag2,
          durationMs: 50,
        );

        expect(report1, equals(report2));
        expect(report1.hashCode, equals(report2.hashCode));
      },
    );

    test('inequality when any single field differs', () {
      const base = VGCamera2ImageReaderFrameSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        sessionConfigured: true,
        repeatingStarted: true,
        frameReceived: true,
        imageClosed: true,
        sessionClosed: true,
        deviceClosed: true,
        imageReaderClosed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        selectedWidth: 640,
        selectedHeight: 480,
        imageFormatName: 'YUV_420_888',
        frameTimestampNs: 1000,
        framePlaneCount: 3,
        decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
        reasons: <String>['r1'],
        events: <String>['e1'],
        diagnostics: <String, Object?>{'k': 'v'},
        durationMs: 100,
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: false,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 33,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: false,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: false,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: false,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: false,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: false,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: false,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: false,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: false,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: false,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: false,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '1',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'front',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 1280,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 720,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'JPEG',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 2000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 1,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameTimeout,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['different_reason'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['different_event'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'other'},
              durationMs: 100,
            ),
          ),
        ),
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2ImageReaderFrameSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              sessionConfigured: true,
              repeatingStarted: true,
              frameReceived: true,
              imageClosed: true,
              sessionClosed: true,
              deviceClosed: true,
              imageReaderClosed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              selectedWidth: 640,
              selectedHeight: 480,
              imageFormatName: 'YUV_420_888',
              frameTimestampNs: 1000,
              framePlaneCount: 3,
              decision: VGCamera2ImageReaderFrameSmokeDecision.frameCaptured,
              reasons: <String>['r1'],
              events: <String>['e1'],
              diagnostics: <String, Object?>{'k': 'v'},
              durationMs: 999,
            ),
          ),
        ),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 5. MethodChannel Invocation & Argument Serialization Contract
  // ─────────────────────────────────────────────────────────────────────────
  group(
    'VGCamera2ImageReaderFrameSmokeReport.runAndroidCamera2ImageReaderFrameSmoke',
    () {
      test(
        'invokes route runAndroidDagPhase3UnitIImageReaderFrameSmoke with default arguments (no cameraId)',
        () async {
          MethodCall? capturedCall;
          const injectedChannel = MethodChannel('test_vanguard_smoke');

          binaryMessenger.setMockMethodCallHandler(injectedChannel, (
            call,
          ) async {
            capturedCall = call;
            return <String, Object?>{
              'success': true,
              'apiLevel': 34,
              'hasCameraPermission': true,
              'attemptedOpen': true,
              'opened': true,
              'sessionConfigured': true,
              'repeatingStarted': true,
              'frameReceived': true,
              'imageClosed': true,
              'sessionClosed': true,
              'deviceClosed': true,
              'imageReaderClosed': true,
              'cameraId': '0',
              'selectedLensFacing': 'back',
              'selectedWidth': 640,
              'selectedHeight': 480,
              'imageFormatName': 'YUV_420_888',
              'frameTimestampNs': 1000,
              'framePlaneCount': 3,
              'decision': 'frameCaptured',
              'reasons': <String>[],
              'events': <String>[
                'openCameraRequested',
                'onOpened',
                'createCaptureSessionRequested',
                'onConfigured',
                'repeatingRequestStarted',
                'onImageAvailable',
                'onSessionClosed',
                'onDeviceClosed',
              ],
              'diagnostics': <String, Object?>{},
              'durationMs': 180,
            };
          });

          final report =
              await VGCamera2ImageReaderFrameSmokeReport.runAndroidCamera2ImageReaderFrameSmoke(
                channel: injectedChannel,
              );

          expect(capturedCall, isNotNull);
          expect(
            capturedCall!.method,
            equals('runAndroidDagPhase3UnitIImageReaderFrameSmoke'),
          );
          final arguments = capturedCall!.arguments as Map<Object?, Object?>;
          expect(arguments.containsKey('cameraId'), isFalse);
          expect(arguments['timeoutMs'], equals(8000));
          expect(arguments['maxWidth'], equals(640));
          expect(arguments['maxHeight'], equals(480));

          expect(report.success, isTrue);
          expect(report.cameraId, equals('0'));
          expect(
            report.decision,
            equals(VGCamera2ImageReaderFrameSmokeDecision.frameCaptured),
          );
        },
      );

      test(
        'passes explicit nonblank cameraId, custom timeout, and custom dimensions',
        () async {
          MethodCall? capturedCall;
          const injectedChannel = MethodChannel('test_vanguard_smoke_custom');

          binaryMessenger.setMockMethodCallHandler(injectedChannel, (
            call,
          ) async {
            capturedCall = call;
            return <String, Object?>{
              'success': true,
              'apiLevel': 34,
              'hasCameraPermission': true,
              'attemptedOpen': true,
              'opened': true,
              'sessionConfigured': true,
              'repeatingStarted': true,
              'frameReceived': true,
              'imageClosed': true,
              'sessionClosed': true,
              'deviceClosed': true,
              'imageReaderClosed': true,
              'cameraId': '1',
              'selectedLensFacing': 'front',
              'selectedWidth': 1280,
              'selectedHeight': 720,
              'imageFormatName': 'YUV_420_888',
              'frameTimestampNs': 2000,
              'framePlaneCount': 3,
              'decision': 'frameCaptured',
              'reasons': <String>[],
              'events': <String>[
                'openCameraRequested',
                'onOpened',
                'createCaptureSessionRequested',
                'onConfigured',
                'repeatingRequestStarted',
                'onImageAvailable',
                'onSessionClosed',
                'onDeviceClosed',
              ],
              'diagnostics': <String, Object?>{},
              'durationMs': 210,
            };
          });

          final report =
              await VGCamera2ImageReaderFrameSmokeReport.runAndroidCamera2ImageReaderFrameSmoke(
                cameraId: '1',
                timeout: const Duration(seconds: 12),
                maxWidth: 1280,
                maxHeight: 720,
                channel: injectedChannel,
              );

          expect(capturedCall, isNotNull);
          expect(
            capturedCall!.method,
            equals('runAndroidDagPhase3UnitIImageReaderFrameSmoke'),
          );
          final arguments = capturedCall!.arguments as Map<Object?, Object?>;
          expect(arguments['cameraId'], equals('1'));
          expect(arguments['timeoutMs'], equals(12000));
          expect(arguments['maxWidth'], equals(1280));
          expect(arguments['maxHeight'], equals(720));

          expect(report.success, isTrue);
          expect(report.cameraId, equals('1'));
          expect(report.selectedLensFacing, equals('front'));
          expect(report.selectedWidth, equals(1280));
          expect(report.selectedHeight, equals(720));
        },
      );

      test('omits blank or whitespace-only cameraId', () async {
        MethodCall? capturedCall;
        const injectedChannel = MethodChannel('test_vanguard_smoke_blank');

        binaryMessenger.setMockMethodCallHandler(injectedChannel, (call) async {
          capturedCall = call;
          return <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'attemptedOpen': true,
            'opened': true,
            'sessionConfigured': true,
            'repeatingStarted': true,
            'frameReceived': true,
            'imageClosed': true,
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'cameraId': '0',
            'selectedLensFacing': 'back',
            'selectedWidth': 640,
            'selectedHeight': 480,
            'imageFormatName': 'YUV_420_888',
            'frameTimestampNs': 1000,
            'framePlaneCount': 3,
            'decision': 'frameCaptured',
            'reasons': <String>[],
            'events': <String>[
              'openCameraRequested',
              'onOpened',
              'createCaptureSessionRequested',
              'onConfigured',
              'repeatingRequestStarted',
              'onImageAvailable',
              'onSessionClosed',
              'onDeviceClosed',
            ],
            'diagnostics': <String, Object?>{},
            'durationMs': 170,
          };
        });

        final report =
            await VGCamera2ImageReaderFrameSmokeReport.runAndroidCamera2ImageReaderFrameSmoke(
              cameraId: '   ',
              channel: injectedChannel,
            );

        expect(capturedCall, isNotNull);
        final arguments = capturedCall!.arguments as Map<Object?, Object?>;
        expect(arguments.containsKey('cameraId'), isFalse);
        expect(arguments['timeoutMs'], equals(8000));
        expect(arguments['maxWidth'], equals(640));
        expect(arguments['maxHeight'], equals(480));
        expect(report.success, isTrue);
      });

      test('uses default vanguard_media_engine channel when omitted', () async {
        MethodCall? capturedCall;
        binaryMessenger.setMockMethodCallHandler(defaultChannel, (call) async {
          capturedCall = call;
          return <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'attemptedOpen': true,
            'opened': true,
            'sessionConfigured': true,
            'repeatingStarted': true,
            'frameReceived': true,
            'imageClosed': true,
            'sessionClosed': true,
            'deviceClosed': true,
            'imageReaderClosed': true,
            'cameraId': '0',
            'selectedLensFacing': 'back',
            'selectedWidth': 640,
            'selectedHeight': 480,
            'imageFormatName': 'YUV_420_888',
            'frameTimestampNs': 1000,
            'framePlaneCount': 3,
            'decision': 'frameCaptured',
            'reasons': <String>[],
            'events': <String>[
              'openCameraRequested',
              'onOpened',
              'createCaptureSessionRequested',
              'onConfigured',
              'repeatingRequestStarted',
              'onImageAvailable',
              'onSessionClosed',
              'onDeviceClosed',
            ],
            'diagnostics': <String, Object?>{},
            'durationMs': 160,
          };
        });

        final report =
            await VGCamera2ImageReaderFrameSmokeReport.runAndroidCamera2ImageReaderFrameSmoke();

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase3UnitIImageReaderFrameSmoke'),
        );
        expect(report.success, isTrue);
      });
    },
  );
}
