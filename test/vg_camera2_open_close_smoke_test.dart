// vg_camera2_open_close_smoke_test.dart
// vanguard_media_engine — Phase 3-Unit H: Android Camera2 single-camera
// open/close lifecycle smoke foundation Dart model & MethodChannel contract tests.

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
  // 1. VGCamera2OpenCloseSmokeDecision Enum and fromRaw Verification
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2OpenCloseSmokeDecision enum & fromRaw', () {
    test('enum has exact expected values in order', () {
      expect(
        VGCamera2OpenCloseSmokeDecision.values,
        orderedEquals(<VGCamera2OpenCloseSmokeDecision>[
          VGCamera2OpenCloseSmokeDecision.openedAndClosed,
          VGCamera2OpenCloseSmokeDecision.permissionRequired,
          VGCamera2OpenCloseSmokeDecision.noCamera,
          VGCamera2OpenCloseSmokeDecision.cameraManagerUnavailable,
          VGCamera2OpenCloseSmokeDecision.cameraUnavailable,
          VGCamera2OpenCloseSmokeDecision.openDisconnected,
          VGCamera2OpenCloseSmokeDecision.openError,
          VGCamera2OpenCloseSmokeDecision.openTimeout,
          VGCamera2OpenCloseSmokeDecision.openFailed,
        ]),
      );
      expect(VGCamera2OpenCloseSmokeDecision.values.length, equals(9));
    });

    test('fromRaw maps known valid decision strings', () {
      expect(
        VGCamera2OpenCloseSmokeDecision.fromRaw('openedAndClosed'),
        equals(VGCamera2OpenCloseSmokeDecision.openedAndClosed),
      );
      expect(
        VGCamera2OpenCloseSmokeDecision.fromRaw('permissionRequired'),
        equals(VGCamera2OpenCloseSmokeDecision.permissionRequired),
      );
      expect(
        VGCamera2OpenCloseSmokeDecision.fromRaw('noCamera'),
        equals(VGCamera2OpenCloseSmokeDecision.noCamera),
      );
      expect(
        VGCamera2OpenCloseSmokeDecision.fromRaw('cameraManagerUnavailable'),
        equals(VGCamera2OpenCloseSmokeDecision.cameraManagerUnavailable),
      );
      expect(
        VGCamera2OpenCloseSmokeDecision.fromRaw('cameraUnavailable'),
        equals(VGCamera2OpenCloseSmokeDecision.cameraUnavailable),
      );
      expect(
        VGCamera2OpenCloseSmokeDecision.fromRaw('openDisconnected'),
        equals(VGCamera2OpenCloseSmokeDecision.openDisconnected),
      );
      expect(
        VGCamera2OpenCloseSmokeDecision.fromRaw('openError'),
        equals(VGCamera2OpenCloseSmokeDecision.openError),
      );
      expect(
        VGCamera2OpenCloseSmokeDecision.fromRaw('openTimeout'),
        equals(VGCamera2OpenCloseSmokeDecision.openTimeout),
      );
      expect(
        VGCamera2OpenCloseSmokeDecision.fromRaw('openFailed'),
        equals(VGCamera2OpenCloseSmokeDecision.openFailed),
      );
    });

    test(
      'fromRaw falls back to openFailed for unknown, non-string, or null values',
      () {
        expect(
          VGCamera2OpenCloseSmokeDecision.fromRaw('unknownDecision'),
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
        expect(
          VGCamera2OpenCloseSmokeDecision.fromRaw(''),
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
        expect(
          VGCamera2OpenCloseSmokeDecision.fromRaw(null),
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
        expect(
          VGCamera2OpenCloseSmokeDecision.fromRaw(123),
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
        expect(
          VGCamera2OpenCloseSmokeDecision.fromRaw(3.14),
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
        expect(
          VGCamera2OpenCloseSmokeDecision.fromRaw(true),
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
        expect(
          VGCamera2OpenCloseSmokeDecision.fromRaw(const <String>[]),
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
        expect(
          VGCamera2OpenCloseSmokeDecision.fromRaw(const <String, Object?>{}),
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 2. VGCamera2OpenCloseSmokeReport fromMap and toMap
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2OpenCloseSmokeReport fromMap and toMap', () {
    test(
      'openedAndClosed decision report parses and serializes all fields cleanly',
      () {
        final rawMap = <String, Object?>{
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': true,
          'attemptedOpen': true,
          'opened': true,
          'closed': true,
          'cameraId': '0',
          'selectedLensFacing': 'back',
          'decision': 'openedAndClosed',
          'reasons': <String>[],
          'events': <String>['openCameraRequested', 'onOpened', 'onClosed'],
          'diagnostics': <String, Object?>{'key': 'val'},
          'durationMs': 120,
        };

        final report = VGCamera2OpenCloseSmokeReport.fromMap(rawMap);
        expect(report.success, isTrue);
        expect(report.apiLevel, equals(34));
        expect(report.hasCameraPermission, isTrue);
        expect(report.attemptedOpen, isTrue);
        expect(report.opened, isTrue);
        expect(report.closed, isTrue);
        expect(report.cameraId, equals('0'));
        expect(report.selectedLensFacing, equals('back'));
        expect(
          report.decision,
          equals(VGCamera2OpenCloseSmokeDecision.openedAndClosed),
        );
        expect(report.reasons, isEmpty);
        expect(
          report.events,
          equals(['openCameraRequested', 'onOpened', 'onClosed']),
        );
        expect(report.diagnostics, equals({'key': 'val'}));
        expect(report.durationMs, equals(120));

        expect(report.isPermissionRequired, isFalse);
        expect(report.isOpenedAndClosed, isTrue);
        expect(report.isAttempted, isTrue);
        expect(report.isClosed, isTrue);

        final serialized = report.toMap();
        expect(serialized['success'], isTrue);
        expect(serialized['apiLevel'], equals(34));
        expect(serialized['hasCameraPermission'], isTrue);
        expect(serialized['attemptedOpen'], isTrue);
        expect(serialized['opened'], isTrue);
        expect(serialized['closed'], isTrue);
        expect(serialized['cameraId'], equals('0'));
        expect(serialized['selectedLensFacing'], equals('back'));
        expect(serialized['decision'], equals('openedAndClosed'));
        expect(serialized['reasons'], isEmpty);
        expect(
          serialized['events'],
          equals(['openCameraRequested', 'onOpened', 'onClosed']),
        );
        expect(serialized['diagnostics'], equals({'key': 'val'}));
        expect(serialized['durationMs'], equals(120));

        final roundTrip = VGCamera2OpenCloseSmokeReport.fromMap(serialized);
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
        'closed': false,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'decision': 'permissionRequired',
        'reasons': <String>['camera_permission_absent'],
        'events': <String>[],
        'diagnostics': <String, Object?>{},
        'durationMs': 5,
      };

      final report = VGCamera2OpenCloseSmokeReport.fromMap(rawMap);
      expect(report.success, isFalse);
      expect(report.apiLevel, equals(34));
      expect(report.hasCameraPermission, isFalse);
      expect(report.attemptedOpen, isFalse);
      expect(report.opened, isFalse);
      expect(report.closed, isFalse);
      expect(
        report.decision,
        equals(VGCamera2OpenCloseSmokeDecision.permissionRequired),
      );
      expect(report.reasons, equals(['camera_permission_absent']));
      expect(report.events, isEmpty);
      expect(report.diagnostics, isEmpty);
      expect(report.durationMs, equals(5));

      expect(report.isPermissionRequired, isTrue);
      expect(report.isOpenedAndClosed, isFalse);
      expect(report.isAttempted, isFalse);
      expect(report.isClosed, isFalse);

      final serialized = report.toMap();
      expect(serialized['decision'], equals('permissionRequired'));
      expect(VGCamera2OpenCloseSmokeReport.fromMap(serialized), equals(report));
    });

    test('noCamera decision parses and serializes cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 33,
        'hasCameraPermission': true,
        'attemptedOpen': false,
        'opened': false,
        'closed': false,
        'cameraId': null,
        'selectedLensFacing': 'unknown',
        'decision': 'noCamera',
        'reasons': <String>['no_camera_available'],
        'events': <String>[],
        'diagnostics': <String, Object?>{},
        'durationMs': 3,
      };

      final report = VGCamera2OpenCloseSmokeReport.fromMap(rawMap);
      expect(report.decision, equals(VGCamera2OpenCloseSmokeDecision.noCamera));
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
        'closed': false,
        'cameraId': null,
        'selectedLensFacing': 'unknown',
        'decision': 'cameraManagerUnavailable',
        'reasons': <String>['camera_manager_unavailable'],
        'events': <String>[],
        'diagnostics': <String, Object?>{},
        'durationMs': 2,
      };

      final report = VGCamera2OpenCloseSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2OpenCloseSmokeDecision.cameraManagerUnavailable),
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
        'closed': false,
        'cameraId': '99',
        'selectedLensFacing': 'unknown',
        'decision': 'cameraUnavailable',
        'reasons': <String>['requested_camera_id_not_found'],
        'events': <String>[],
        'diagnostics': <String, Object?>{},
        'durationMs': 4,
      };

      final report = VGCamera2OpenCloseSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2OpenCloseSmokeDecision.cameraUnavailable),
      );
      expect(report.cameraId, equals('99'));
      expect(report.reasons, equals(['requested_camera_id_not_found']));
    });

    test('openDisconnected decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': true,
        'opened': false,
        'closed': false,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'decision': 'openDisconnected',
        'reasons': <String>['camera_disconnected'],
        'events': <String>['openCameraRequested', 'onDisconnected'],
        'diagnostics': <String, Object?>{},
        'durationMs': 50,
      };

      final report = VGCamera2OpenCloseSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2OpenCloseSmokeDecision.openDisconnected),
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
        'closed': false,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'decision': 'openError',
        'reasons': <String>['camera_open_error'],
        'events': <String>['openCameraRequested', 'onError:3'],
        'diagnostics': <String, Object?>{'errorCode': 3},
        'durationMs': 60,
      };

      final report = VGCamera2OpenCloseSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2OpenCloseSmokeDecision.openError),
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
        'closed': false,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'decision': 'openTimeout',
        'reasons': <String>['camera_open_timeout'],
        'events': <String>['openCameraRequested', 'openTimeout'],
        'diagnostics': <String, Object?>{},
        'durationMs': 5002,
      };

      final report = VGCamera2OpenCloseSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2OpenCloseSmokeDecision.openTimeout),
      );
      expect(report.reasons, equals(['camera_open_timeout']));
      expect(report.durationMs, equals(5002));
    });

    test('openFailed decision parses cleanly', () {
      final rawMap = <String, Object?>{
        'success': false,
        'apiLevel': 34,
        'hasCameraPermission': true,
        'attemptedOpen': true,
        'opened': false,
        'closed': false,
        'cameraId': '0',
        'selectedLensFacing': 'back',
        'decision': 'openFailed',
        'reasons': <String>['camera_open_failed'],
        'events': <String>['openCameraRequested'],
        'diagnostics': <String, Object?>{
          'openCameraError': 'SecurityException',
        },
        'durationMs': 20,
      };

      final report = VGCamera2OpenCloseSmokeReport.fromMap(rawMap);
      expect(
        report.decision,
        equals(VGCamera2OpenCloseSmokeDecision.openFailed),
      );
      expect(report.reasons, equals(['camera_open_failed']));
    });

    test(
      'fromMap handles malformed non-map inputs by preserving raw in diagnostics and using reason native_result_not_a_map',
      () {
        final nullReport = VGCamera2OpenCloseSmokeReport.fromMap(null);
        expect(nullReport.success, isFalse);
        expect(nullReport.apiLevel, equals(0));
        expect(nullReport.hasCameraPermission, isFalse);
        expect(nullReport.attemptedOpen, isFalse);
        expect(nullReport.opened, isFalse);
        expect(nullReport.closed, isFalse);
        expect(nullReport.cameraId, isNull);
        expect(nullReport.selectedLensFacing, equals('unknown'));
        expect(
          nullReport.decision,
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
        expect(nullReport.reasons, equals(['native_result_not_a_map']));
        expect(nullReport.events, isEmpty);
        expect(nullReport.diagnostics, equals({'raw': null}));
        expect(nullReport.durationMs, equals(0));

        final strReport = VGCamera2OpenCloseSmokeReport.fromMap('not_a_map');
        expect(strReport.success, isFalse);
        expect(
          strReport.decision,
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
        expect(strReport.reasons, equals(['native_result_not_a_map']));
        expect(strReport.diagnostics, equals({'raw': 'not_a_map'}));

        final numReport = VGCamera2OpenCloseSmokeReport.fromMap(999);
        expect(numReport.success, isFalse);
        expect(numReport.diagnostics, equals({'raw': 999}));

        final listReport = VGCamera2OpenCloseSmokeReport.fromMap(<Object?>[
          'a',
          'b',
        ]);
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
      'fromMap handles missing/malformed list/map fields defensively producing empty collections',
      () {
        final mapWithNulls = <Object?, Object?>{
          'success': null,
          'apiLevel': null,
          'hasCameraPermission': null,
          'attemptedOpen': null,
          'opened': null,
          'closed': null,
          'cameraId': null,
          'selectedLensFacing': null,
          'decision': null,
          'reasons': null,
          'events': null,
          'diagnostics': null,
          'durationMs': null,
        };

        final report = VGCamera2OpenCloseSmokeReport.fromMap(mapWithNulls);
        expect(report.success, isFalse);
        expect(report.apiLevel, equals(0));
        expect(report.hasCameraPermission, isFalse);
        expect(report.attemptedOpen, isFalse);
        expect(report.opened, isFalse);
        expect(report.closed, isFalse);
        expect(report.cameraId, isNull);
        expect(report.selectedLensFacing, equals('unknown'));
        expect(
          report.decision,
          equals(VGCamera2OpenCloseSmokeDecision.openFailed),
        );
        expect(report.reasons, isEmpty);
        expect(report.events, isEmpty);
        expect(report.diagnostics, isEmpty);
        expect(report.durationMs, equals(0));

        // Map with doubles / non-list structures / mixed list elements
        final mapWithMixed = <Object?, Object?>{
          'success': true,
          'apiLevel': 34.0,
          'durationMs': 150.0,
          'reasons': <Object?>['r1', 123, null],
          'events': <Object?>['e1', 456],
          'diagnostics': <Object?, Object?>{'nested': 'ok'},
        };

        final parsed = VGCamera2OpenCloseSmokeReport.fromMap(mapWithMixed);
        expect(parsed.apiLevel, equals(34));
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
        final parsedBad = VGCamera2OpenCloseSmokeReport.fromMap(
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
  group('VGCamera2OpenCloseSmokeReport getters', () {
    test('isPermissionRequired reflects decision strictly', () {
      const permReport = VGCamera2OpenCloseSmokeReport(
        success: false,
        apiLevel: 34,
        hasCameraPermission: false,
        attemptedOpen: false,
        opened: false,
        closed: false,
        cameraId: '0',
        selectedLensFacing: 'back',
        decision: VGCamera2OpenCloseSmokeDecision.permissionRequired,
        reasons: <String>['camera_permission_absent'],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 5,
      );
      expect(permReport.isPermissionRequired, isTrue);

      const okReport = VGCamera2OpenCloseSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        closed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
        reasons: <String>[],
        events: <String>['onOpened', 'onClosed'],
        diagnostics: <String, Object?>{},
        durationMs: 100,
      );
      expect(okReport.isPermissionRequired, isFalse);
    });

    test('isOpenedAndClosed reflects decision strictly', () {
      const okReport = VGCamera2OpenCloseSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        closed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
        reasons: <String>[],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 100,
      );
      expect(okReport.isOpenedAndClosed, isTrue);

      const failedReport = VGCamera2OpenCloseSmokeReport(
        success: false,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: false,
        closed: false,
        cameraId: '0',
        selectedLensFacing: 'back',
        decision: VGCamera2OpenCloseSmokeDecision.openFailed,
        reasons: <String>[],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 100,
      );
      expect(failedReport.isOpenedAndClosed, isFalse);
    });

    test('isAttempted mirrors attemptedOpen exactly', () {
      const attempted = VGCamera2OpenCloseSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        closed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
        reasons: <String>[],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 100,
      );
      expect(attempted.isAttempted, isTrue);

      const notAttempted = VGCamera2OpenCloseSmokeReport(
        success: false,
        apiLevel: 34,
        hasCameraPermission: false,
        attemptedOpen: false,
        opened: false,
        closed: false,
        cameraId: null,
        selectedLensFacing: 'unknown',
        decision: VGCamera2OpenCloseSmokeDecision.permissionRequired,
        reasons: <String>[],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 0,
      );
      expect(notAttempted.isAttempted, isFalse);
    });

    test('isClosed mirrors closed exactly', () {
      const closedReport = VGCamera2OpenCloseSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        closed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
        reasons: <String>[],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 100,
      );
      expect(closedReport.isClosed, isTrue);

      const notClosedReport = VGCamera2OpenCloseSmokeReport(
        success: false,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        closed: false,
        cameraId: '0',
        selectedLensFacing: 'back',
        decision: VGCamera2OpenCloseSmokeDecision.openTimeout,
        reasons: <String>[],
        events: <String>[],
        diagnostics: <String, Object?>{},
        durationMs: 5000,
      );
      expect(notClosedReport.isClosed, isFalse);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Equality, hashCode, toString, and Stable Diagnostics Hash
  // ─────────────────────────────────────────────────────────────────────────
  group('VGCamera2OpenCloseSmokeReport value semantics', () {
    test('identical instances and identical values evaluate equal', () {
      const a = VGCamera2OpenCloseSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        closed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
        reasons: <String>['ok'],
        events: <String>['onOpened', 'onClosed'],
        diagnostics: <String, Object?>{'k': 'v'},
        durationMs: 100,
      );

      const b = VGCamera2OpenCloseSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        closed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
        reasons: <String>['ok'],
        events: <String>['onOpened', 'onClosed'],
        diagnostics: <String, Object?>{'k': 'v'},
        durationMs: 100,
      );

      expect(identical(a, a), isTrue);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a.toString(), contains('VGCamera2OpenCloseSmokeReport('));
      expect(
        a.toString(),
        contains('decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed'),
      );
      expect(a.toString(), contains('success: true'));
      expect(a.toString(), contains('apiLevel: 34'));
      expect(a.toString(), contains('cameraId: 0'));
      expect(a.toString(), contains('durationMs: 100'));
    });

    test(
      'stable diagnostics hash produces equal hash and equality with different map key order',
      () {
        final diag1 = <String, Object?>{'alpha': 1, 'beta': 2, 'gamma': 3};
        final diag2 = <String, Object?>{'gamma': 3, 'alpha': 1, 'beta': 2};

        final report1 = VGCamera2OpenCloseSmokeReport(
          success: true,
          apiLevel: 34,
          hasCameraPermission: true,
          attemptedOpen: true,
          opened: true,
          closed: true,
          cameraId: '0',
          selectedLensFacing: 'back',
          decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
          reasons: const <String>['r1'],
          events: const <String>['e1'],
          diagnostics: diag1,
          durationMs: 50,
        );

        final report2 = VGCamera2OpenCloseSmokeReport(
          success: true,
          apiLevel: 34,
          hasCameraPermission: true,
          attemptedOpen: true,
          opened: true,
          closed: true,
          cameraId: '0',
          selectedLensFacing: 'back',
          decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
      const base = VGCamera2OpenCloseSmokeReport(
        success: true,
        apiLevel: 34,
        hasCameraPermission: true,
        attemptedOpen: true,
        opened: true,
        closed: true,
        cameraId: '0',
        selectedLensFacing: 'back',
        decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
        reasons: <String>['r1'],
        events: <String>['e1'],
        diagnostics: <String, Object?>{'k': 'v'},
        durationMs: 100,
      );

      expect(
        base,
        isNot(
          equals(
            const VGCamera2OpenCloseSmokeReport(
              success: false,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 33,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: false,
              attemptedOpen: true,
              opened: true,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: false,
              opened: true,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: false,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              closed: false,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              closed: true,
              cameraId: '1',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'front',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openTimeout,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
            const VGCamera2OpenCloseSmokeReport(
              success: true,
              apiLevel: 34,
              hasCameraPermission: true,
              attemptedOpen: true,
              opened: true,
              closed: true,
              cameraId: '0',
              selectedLensFacing: 'back',
              decision: VGCamera2OpenCloseSmokeDecision.openedAndClosed,
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
  group('VGCamera2OpenCloseSmokeReport.runAndroidCamera2OpenCloseSmoke', () {
    test(
      'invokes route runAndroidDagPhase3UnitHCameraOpenCloseSmoke with default arguments (no cameraId)',
      () async {
        MethodCall? capturedCall;
        const injectedChannel = MethodChannel('test_vanguard_smoke');

        binaryMessenger.setMockMethodCallHandler(injectedChannel, (call) async {
          capturedCall = call;
          return <String, Object?>{
            'success': true,
            'apiLevel': 34,
            'hasCameraPermission': true,
            'attemptedOpen': true,
            'opened': true,
            'closed': true,
            'cameraId': '0',
            'selectedLensFacing': 'back',
            'decision': 'openedAndClosed',
            'reasons': <String>[],
            'events': <String>['openCameraRequested', 'onOpened', 'onClosed'],
            'diagnostics': <String, Object?>{},
            'durationMs': 80,
          };
        });

        final report =
            await VGCamera2OpenCloseSmokeReport.runAndroidCamera2OpenCloseSmoke(
              channel: injectedChannel,
            );

        expect(capturedCall, isNotNull);
        expect(
          capturedCall!.method,
          equals('runAndroidDagPhase3UnitHCameraOpenCloseSmoke'),
        );
        final arguments = capturedCall!.arguments as Map<Object?, Object?>;
        expect(arguments.containsKey('cameraId'), isFalse);
        expect(arguments['timeoutMs'], equals(5000));

        expect(report.success, isTrue);
        expect(report.cameraId, equals('0'));
        expect(
          report.decision,
          equals(VGCamera2OpenCloseSmokeDecision.openedAndClosed),
        );
      },
    );

    test('passes explicit nonblank cameraId and custom timeout', () async {
      MethodCall? capturedCall;
      const injectedChannel = MethodChannel('test_vanguard_smoke_custom');

      binaryMessenger.setMockMethodCallHandler(injectedChannel, (call) async {
        capturedCall = call;
        return <String, Object?>{
          'success': true,
          'apiLevel': 34,
          'hasCameraPermission': true,
          'attemptedOpen': true,
          'opened': true,
          'closed': true,
          'cameraId': '1',
          'selectedLensFacing': 'front',
          'decision': 'openedAndClosed',
          'reasons': <String>[],
          'events': <String>['openCameraRequested', 'onOpened', 'onClosed'],
          'diagnostics': <String, Object?>{},
          'durationMs': 95,
        };
      });

      final report =
          await VGCamera2OpenCloseSmokeReport.runAndroidCamera2OpenCloseSmoke(
            cameraId: '1',
            timeout: const Duration(seconds: 8),
            channel: injectedChannel,
          );

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase3UnitHCameraOpenCloseSmoke'),
      );
      final arguments = capturedCall!.arguments as Map<Object?, Object?>;
      expect(arguments['cameraId'], equals('1'));
      expect(arguments['timeoutMs'], equals(8000));

      expect(report.success, isTrue);
      expect(report.cameraId, equals('1'));
      expect(report.selectedLensFacing, equals('front'));
    });

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
          'closed': true,
          'cameraId': '0',
          'selectedLensFacing': 'back',
          'decision': 'openedAndClosed',
          'reasons': <String>[],
          'events': <String>['openCameraRequested', 'onOpened', 'onClosed'],
          'diagnostics': <String, Object?>{},
          'durationMs': 70,
        };
      });

      final report =
          await VGCamera2OpenCloseSmokeReport.runAndroidCamera2OpenCloseSmoke(
            cameraId: '   ',
            channel: injectedChannel,
          );

      expect(capturedCall, isNotNull);
      final arguments = capturedCall!.arguments as Map<Object?, Object?>;
      expect(arguments.containsKey('cameraId'), isFalse);
      expect(arguments['timeoutMs'], equals(5000));
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
          'closed': true,
          'cameraId': '0',
          'selectedLensFacing': 'back',
          'decision': 'openedAndClosed',
          'reasons': <String>[],
          'events': <String>['openCameraRequested', 'onOpened', 'onClosed'],
          'diagnostics': <String, Object?>{},
          'durationMs': 60,
        };
      });

      final report =
          await VGCamera2OpenCloseSmokeReport.runAndroidCamera2OpenCloseSmoke();

      expect(capturedCall, isNotNull);
      expect(
        capturedCall!.method,
        equals('runAndroidDagPhase3UnitHCameraOpenCloseSmoke'),
      );
      expect(report.success, isTrue);
    });
  });
}
